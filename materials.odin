package main
import "base:runtime"
import "core:reflect"
import "core:log"
import "core:container/queue"
import "core:container/handle_map"
@(require) import "core:slice"
@(require) import "core:mem"
@(require) import "core:strings"

Materials :: struct {
	pool:           Pool_Buffer,
	allocator:      runtime.Allocator,
	pending_frees:  queue.Queue(Pending_Free),
	handle_map:     handle_map.Dynamic_Handle_Map(Material_Slot, Material_Handle),
	dirty:          [dynamic]Material_Handle,
	dependents:     [dynamic]Texture_Dependents,
	types:          [dynamic]Material_Type,
	type_by_params: map[typeid]Material_Type_Id,
}

Material_Info :: struct {
	type: Material_Type_Id,
	address: Device_Address,
}

Materials_Create_Error :: union #shared_nil {
	Buffer_Error,
	Material_Error,
}

Material_Type_Id :: distinct u32

@(private="file")
Material_Type :: struct {
	name:         string,
	params_type:  typeid,
	data_size:    int,
	data_align:   int,
	properties:   Material_Properties,
	resolve_proc: rawptr,
	resolve:      Resolve_Trampoline,
}

@(private="file")
Resolve_Trampoline :: #type proc(
	textures: ^Textures,
	out: []byte,
	params: rawptr,
	resolve: rawptr,
)

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
	type:         Material_Type_Id,
	params:       []byte,
	data:         Pool_Subbuffer(byte),
	dependencies: [dynamic]Material_Dependency,
	dirty:        Material_Dirty_Level,
	fresh:        bool,
}

@(private="file")
Pending_Free :: struct {
	retire_value: u64,
	data:         Pool_Subbuffer(byte),
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
	materials.types = make([dynamic]Material_Type, allocator)
	materials.type_by_params = make(map[typeid]Material_Type_Id, allocator)

	handle_map.dynamic_init(&materials.handle_map, allocator)
	queue.init(&materials.pending_frees, queue.DEFAULT_CAPACITY, allocator)

	defer if err != nil {
		materials_destroy(materials, device)
	}

	return nil
}

materials_destroy :: proc(materials: ^Materials, device: Device) {
	if materials == nil {
		return
	}

	for type in materials.types {
		delete(type.name, materials.allocator)
	}

	for dependents in materials.dependents {
		delete(dependents.dependents)
	}
	
	iterator := handle_map.iterator_make(&materials.handle_map)
	for slot, _ in handle_map.iterate(&iterator) {
		delete(slot.dependencies)
		delete(slot.params, materials.allocator)
	}

	delete(materials.dirty)
	delete(materials.dependents)
	delete(materials.types)
	delete(materials.type_by_params)
	handle_map.dynamic_destroy(&materials.handle_map)
	queue.destroy(&materials.pending_frees)
	pool_destroy(&materials.pool, device)
	materials^ = {}
}

materials_add :: proc(
	materials: ^Materials, 
	params: $P,
) -> (handle: Material_Handle, err: Material_Error) {
	assert(materials != nil)

	type, type_id := get_params_material_type(materials, P) or_return
	data, ok := pool_make(&materials.pool, []byte, type.data_size, type.data_align)
	if !ok {
		return {}, .Out_Of_Gpu_Memory
	}

	handle = handle_map.add(&materials.handle_map, {
		dirty = .Params,
		fresh = true,
		data = data,
		type = type_id,
		params = make_params(params, materials.allocator),
		dependencies = make([dynamic]Material_Dependency, materials.allocator),
	})

	append(&materials.dirty, handle)
	return handle, nil
}

materials_replace :: proc(
	materials: ^Materials, 
	frame_ring: Frame_Ring,
	handle: Material_Handle, 
	params: $P,
) -> Material_Error {
	assert(materials != nil)
	
	slot, slot_ok := handle_map.get(&materials.handle_map, handle)
	if !slot_ok {
		return .Invalid_Handle
	}
	
	type, type_id := get_params_material_type(materials, P) or_return
	new_data, new_data_ok := pool_make(&materials.pool, []byte, type.data_size, type.data_align)
	if !new_data_ok {
		return .Out_Of_Gpu_Memory
	}

	defer_free(materials, frame_ring, slot)
	delete(slot.params, materials.allocator)
	slot.params = make_params(params, materials.allocator)
	slot.type = type_id
	slot.data = new_data
	slot.fresh = true
	mark(materials, slot, .Params)

	return nil
}

@(private="file", require_results)
get_params_material_type :: proc(
	materials: ^Materials, 
	$P: typeid
) -> (^Material_Type, Material_Type_Id, Material_Error) {
	type_id, ok := materials.type_by_params[P]
	if !ok {
		return nil, 0, .Type_Not_Registered
	}

	return &materials.types[type_id], type_id, nil
}

@(private="file", require_results)
make_params :: proc(params: $P, allocator := context.allocator) -> []byte {
	params_bytes := make([]byte, size_of(P), allocator)
	params_typed := slice.reinterpret([]P, params_bytes)
	params_typed[0] = params
	return params_bytes
}

materials_remove :: proc(materials: ^Materials, frame_ring: Frame_Ring, handle: Material_Handle) {
	assert(materials != nil)

	if slot, ok := handle_map.get(&materials.handle_map, handle); ok {
		unlink_all(materials, slot)
		delete(slot.dependencies)
		delete(slot.params, materials.allocator)
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

		type := &materials.types[slot.type]

		if slot.dirty >= .Textures {
			if !slot.fresh {
				new_data, new_data_ok := pool_make(&materials.pool, []u8, type.data_size, type.data_align)
				if !new_data_ok {
					log.error("Out of GPU memory for materials")
					append(&retry, material)
					continue
				}
				defer_free(materials, frame_ring, slot)
				slot.data = new_data
			}

			data := make_aligned([]byte, type.data_size, type.data_align, context.temp_allocator)
			type.resolve(textures, data, raw_data(slot.params), type.resolve_proc)
			copy(slot.data.mapped, data)

			if err := pool_subbuffer_flush(slot.data, device); err != nil {
				log.error("Failed to flush material data")
			}
		}

		if slot.dirty >= .Params {
			unlink_all(materials, slot)
			resolve_texture_dependencies(&deps, slot.params, type.params_type)
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

@(private="file")
resolve_texture_dependencies :: proc(
	out: ^[dynamic]Texture_Handle, 
	params: []byte, 
	params_type: typeid
) {
	collect_textures(out, transmute(any)runtime.Raw_Any{
		data = raw_data(params), 
		id = params_type,
	})	
}

@(private="file")
collect_textures :: proc(out: ^[dynamic]Texture_Handle, value: any) {
    if value.data == nil {
        return
    }

    if value.id == typeid_of(Texture_Handle) {
        handle := (^Texture_Handle)(value.data)^
        if handle != {} {
            append(out, handle)
        }
        return
    }

    #partial switch v in runtime.type_info_base(type_info_of(value.id)).variant {
    case runtime.Type_Info_Union:
        collect_textures(out, reflect.get_union_variant(value))
    case runtime.Type_Info_Struct:
        for i in 0..<reflect.struct_field_count(value.id) {
            field := reflect.struct_field_at(value.id, i)
            collect_textures(out, reflect.struct_field_value(value, field))
        }
    case runtime.Type_Info_Array, runtime.Type_Info_Enumerated_Array,
         runtime.Type_Info_Slice, runtime.Type_Info_Dynamic_Array:
        for i in 0..<reflect.length(value) {
            collect_textures(out, reflect.index(value, i))
        }
    }
}

materials_register_type :: proc(
	materials: ^Materials,
	$P, $D: typeid,
	name: string,
	properties: Material_Properties,
	resolve: proc(^Textures, P) -> D,
) -> Material_Type_Id {
	assert(materials != nil)
	assert(P not_in materials.type_by_params, "Material type already registered")

	id := Material_Type_Id(len(materials.types))
	append(&materials.types, {
		name = strings.clone(name, materials.allocator),
		properties = properties,
		params_type = P,
		data_size = size_of(D),
		data_align = max(align_of(D), 16),
		resolve_proc = rawptr(resolve),
		resolve = make_trampoline(P, D),
	})

	materials.type_by_params[P] = id
	return id
}

@(private="file")
make_trampoline :: proc($P, $D: typeid) -> Resolve_Trampoline {
	return proc(textures: ^Textures, out: []byte, params: rawptr, resolve: rawptr) {
		typed_resolve := cast(proc(^Textures, P) -> D)resolve
		resolved_data := typed_resolve(textures, (^P)(params)^)
		assert(len(out) == size_of(D))
		copy(out, mem.ptr_to_bytes(&resolved_data))
	}
}

materials_get :: proc(
	materials: ^Materials, 
	handle: Material_Handle,
	$P: typeid,
) -> (P, Material_Error) {
	assert(materials != nil)
	if slot, slot_ok := handle_map.get(&materials.handle_map, handle); slot_ok {
		type_id, type_ok := materials.type_by_params[P]
		if !type_ok {
			return {}, .Type_Not_Registered
		}
		if type_id != slot.type {
			return {}, .Type_Does_Not_Match	
		}

		typed_params := slice.reinterpret([]P, slot.params)
		return typed_params[0], nil
	}
	return {}, .Invalid_Handle
}

materials_get_info :: proc(
	materials: ^Materials, 
	handle: Material_Handle,
) -> (Material_Info, bool) {
	assert(materials != nil)
	if slot, ok := handle_map.get(&materials.handle_map, handle); ok {
		return {
			type = slot.type,
			address = slot.data.address,
		}, true
	}
	return {}, false
}
