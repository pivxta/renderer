package main
import "base:runtime"
import "core:log"
import "core:slice"
import "core:container/queue"
import "core:container/handle_map"

Materials :: struct {
	pool:          Pool_Buffer,
	allocator:     runtime.Allocator,
	pending_frees: queue.Queue(Pending_Free),
	handle_map:    handle_map.Dynamic_Handle_Map(Material_Slot, Material_Handle),
	dirty:         [dynamic]Material_Handle,
	dependents:    [dynamic]Texture_Dependents,

	default_material: Material_Handle,
	error_material: Material_Handle,
}

Materials_Create_Error :: union #shared_nil {
	Buffer_Error,
	Material_Error,
}

@(private="file")
Texture_Dependents :: struct {
	generation: u32,
	dependents: [dynamic]Texture_Dependent,
}

@(private="file")
Texture_Dependent :: struct {
	material: Material_Handle,
	index:    int,
}

@(private="file")
Material_Dependency :: struct {
	texture: Texture_Handle,
	index:   int,
}

@(private="file")
Material_Dirty_Level :: enum {
	None,
	Textures,
	Params,
}

@(private="file")
Material_Slot :: struct {
	handle:       Material_Handle,
	params:       Material,
	data:         Pool_Subbuffer(u8),
	dependencies: [dynamic]Material_Dependency,
	dirty:        Material_Dirty_Level,
	fresh:        bool,
}

@(private="file")
Pending_Free :: struct {
	retire_value: u64,
	data:         Pool_Subbuffer(u8),
}

@(require_results)
materials_init :: proc(
	materials: ^Materials, 
	device: Device, 
	capacity: int,
	allocator := context.allocator,
) -> (err: Materials_Create_Error) {
	assert(materials != nil)
	
	pool_init(
		&materials.pool, device,
		capacity = capacity,
		buffer_usage = {.STORAGE_BUFFER, .SHADER_DEVICE_ADDRESS},
		memory_usage = .AUTO_PREFER_DEVICE,
		memory_flags = {.MAPPED, .HOST_ACCESS_SEQUENTIAL_WRITE},
	) or_return

	materials.allocator = allocator
	materials.dependents = make([dynamic]Texture_Dependents, allocator)
	materials.dirty = make([dynamic]Material_Handle, allocator)

	handle_map.dynamic_init(&materials.handle_map, allocator)
	queue.init(&materials.pending_frees, queue.DEFAULT_CAPACITY, allocator)

	defer if err != nil {
		materials_destroy(materials, device)
	}

	materials.default_material = materials_add(materials, get_material_fallback(.Default)) or_return
	materials.error_material = materials_add(materials, get_material_fallback(.Error)) or_return
	return nil
}

materials_destroy :: proc(materials: ^Materials, device: Device) {
	if materials == nil {
		return
	}

	for dependents in materials.dependents {
		delete(dependents.dependents)
	}
	
	iterator := handle_map.iterator_make(&materials.handle_map)
	for slot, _ in handle_map.iterate(&iterator) {
		delete(slot.dependencies)
	}

	delete(materials.dirty)
	delete(materials.dependents)
	handle_map.dynamic_destroy(&materials.handle_map)
	queue.destroy(&materials.pending_frees)
	pool_destroy(&materials.pool, device)
	materials^ = {}
}

materials_add :: proc(
	materials: ^Materials, 
	material: Material,
) -> (handle: Material_Handle, err: Material_Error) {
	assert(materials != nil)

	data, ok := pool_make(&materials.pool, []u8, size_of(Material_Data))
	if !ok {
		return {}, .Out_Of_Gpu_Memory
	}

	handle = handle_map.add(&materials.handle_map, {
		dirty = .Params,
		fresh = true,
		data = data,
		params = material,
		dependencies = make([dynamic]Material_Dependency, materials.allocator),
	})

	append(&materials.dirty, handle)
	return handle, nil
}

materials_replace :: proc(
	materials: ^Materials, 
	frame_ring: Frame_Ring,
	handle: Material_Handle, 
	material: Material,
) -> Material_Error {
	assert(materials != nil)
	assert(handle != materials.default_material && handle != materials.error_material)
	
	slot, slot_ok := handle_map.get(&materials.handle_map, handle)
	if !slot_ok {
		return .Invalid_Handle
	}
	
	new_data, new_data_ok := pool_make(&materials.pool, []u8, size_of(Material_Data))
	if !new_data_ok {
		return .Out_Of_Gpu_Memory
	}

	defer_free(materials, frame_ring, slot)
	slot.params = material
	slot.data = new_data
	slot.fresh = true
	mark(materials, slot, .Params)

	return nil
}

materials_remove :: proc(materials: ^Materials, frame_ring: Frame_Ring, handle: Material_Handle) {
	assert(materials != nil)
	assert(handle != materials.default_material && handle != materials.error_material)

	if slot, ok := handle_map.get(&materials.handle_map, handle); ok {
		unlink_all(materials, slot)
		delete(slot.dependencies)
		defer_free(materials, frame_ring, slot)
		handle_map.remove(&materials.handle_map, handle)
	}
}

@(private="file")
defer_free :: proc(materials: ^Materials, frame_ring: Frame_Ring, slot: ^Material_Slot) {
	queue.enqueue(&materials.pending_frees, {
		retire_value = frame_ring.timeline_value + 1,
		data = slot.data,
	})
}

@(private="file")
mark :: proc(materials: ^Materials, slot: ^Material_Slot, level: Material_Dirty_Level) {
	if slot.dirty == .None {
		append(&materials.dirty, slot.handle)
	}
	slot.dirty = max(slot.dirty, level)
}

@(private="file")
get_dependents :: proc(
	materials: ^Materials, 
	texture: Texture_Handle,
	create: bool,
) -> ^[dynamic]Texture_Dependent {
	index := int(texture.idx)
	if index >= len(materials.dependents) {
		if !create {
			return nil
		}
		resize(&materials.dependents, index + 1)
	}

	entry := &materials.dependents[index]
	if entry.generation != texture.gen {
		if !create {
			return nil
		}
		clear(&entry.dependents)
		entry.generation = texture.gen
	}
	return &entry.dependents
}

@(private="file")
link :: proc(
	materials: ^Materials, 
	slot: ^Material_Slot,
	texture: Texture_Handle,
) {
	dependents := get_dependents(materials, texture, create=true)

	i := len(slot.dependencies)
	j := len(dependents)

	append(&slot.dependencies, {texture = texture, index = j})
	append(dependents,         {material = slot.handle, index = i})
}

@(private="file")
unlink :: proc(materials: ^Materials, slot: ^Material_Slot, i: int) {
	dependency := slot.dependencies[i]

	if dependents := get_dependents(materials, dependency.texture, create=false); dependents != nil {
		j := dependency.index
		last := len(dependents) - 1
		if last != j {
			moved := dependents[last]
			dependents[j] = moved

			moved_slot, ok := handle_map.get(&materials.handle_map, moved.material)
			assert(ok, "Dependent material was removed without linking")
			moved_slot.dependencies[moved.index].index = j
		}
		pop(dependents)
	}

	last := len(slot.dependencies) - 1
	if last != i {
		moved := slot.dependencies[last]
		slot.dependencies[i] = moved

		if dependents := get_dependents(materials, moved.texture, create=false); dependents != nil {
			dependents[moved.index].index = i				
		}
	}
	pop(&slot.dependencies)
}

@(private="file")
unlink_all :: proc(materials: ^Materials, slot: ^Material_Slot) {
	for i := len(slot.dependencies) - 1; i >= 0; i -= 1 {
		unlink(materials, slot, i)
	}
}

materials_destroy_pending :: proc(materials: ^Materials, finished_value: u64) {
	assert(materials != nil)
	
	for queue.len(materials.pending_frees) > 0 {
		pending_free := queue.front_ptr(&materials.pending_frees)
		if pending_free.retire_value <= finished_value {
			pool_free(&materials.pool, &pending_free.data)
			queue.dequeue(&materials.pending_frees)
		} else {
			break	
		}
	}
}

materials_mark_dirty :: proc(materials: ^Materials, updates: []Texture_Update) {
	assert(materials != nil)
	
	for update in updates {
		dependents := get_dependents(materials, update.handle, create=false)
		if dependents == nil {
			continue
		}

		if update.kind == .Remove {
			for len(dependents) > 0 {
				dependent := dependents[len(dependents) - 1]
				slot, ok := handle_map.get(&materials.handle_map, dependent.material)
				assert(ok)
				mark(materials, slot, .Textures)
				unlink(materials, slot, dependent.index)
			}
		} else {
			for dependent in dependents {
				slot, ok := handle_map.get(&materials.handle_map, dependent.material)
				assert(ok)
				mark(materials, slot, .Textures)
			}
		}
		
	}
}

materials_update_dirty :: proc(
	materials: ^Materials, 
	textures: ^Textures, 
	device: Device,
	frame_ring: Frame_Ring, 
) {
	assert(materials != nil)

	retry := make([dynamic]Material_Handle, context.temp_allocator)
	deps := make([dynamic]Texture_Handle, context.temp_allocator)
	for material in materials.dirty {
		slot, ok := handle_map.get(&materials.handle_map, material)
		if !ok {
			continue
		}
		
		if slot.dirty >= .Textures {
			if !slot.fresh {
				new_data, new_data_ok := pool_make(&materials.pool, []u8, size_of(Material_Data))
				if !new_data_ok {
					log.error("Out of GPU memory for materials")
					append(&retry, material)
					continue
				}
				defer_free(materials, frame_ring, slot)
				slot.data = new_data
			}

			material_data := resolve_material(textures, slot.params)
			typed_data := slice.reinterpret([]Material_Data, slot.data.mapped)
			typed_data[0] = material_data
			if err := pool_subbuffer_flush(slot.data, device); err != nil {
				log.error("Failed to flush material data")
			}
		}

		if slot.dirty >= .Params {
			unlink_all(materials, slot)
			resolve_texture_dependencies(&deps, slot.params)
			for dep in deps {
				if textures_is_valid(textures, dep) {
					link(materials, slot, dep)
				}
			}
			clear(&deps)
		}

		slot.dirty = .None
		slot.fresh = false
	}

	clear(&materials.dirty)
	append(&materials.dirty, ..retry[:])
}

materials_get_address :: proc(
	materials: ^Materials, 
	handle: Material_Handle,
) -> Device_Address {
	assert(materials != nil)
	if slot, ok := handle_map.get(&materials.handle_map, handle); ok {
		return slot.data.address
	}

	fallback := materials.default_material if handle == {} else materials.error_material
	slot := handle_map.get(&materials.handle_map, fallback)
	return slot.data.address
}
