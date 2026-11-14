package main
import "core:container/handle_map"
import "core:container/queue"

Meshes :: struct {
	mesh_pool:     Pool_Buffer,
	index_pool:    Pool_Buffer,
	handle_map:    handle_map.Dynamic_Handle_Map(Mesh_Slot, Mesh_Handle),
	pending_frees: queue.Queue(Pending_Free),
}

Mesh_Info :: struct {
	first_index:    u32,
	index_count:    u32,
	vertex_count:   u32,
	attributes:     Vertex_Attribute_Set,
	record_address: Device_Address,
}

Mesh_Record_Data :: struct {
	data_address: Device_Address,
	data_offsets: [Vertex_Attribute]u32,
	encodings:    [Vertex_Attribute]u8,
	divisors:     [Vertex_Attribute]u32,
	attributes:   Vertex_Attribute_Set,
	vertex_count: u32,
}

Mesh_Slot :: struct {
	handle:       Mesh_Handle,
	loaded:       bool,
	index_count:  u32,
	vertex_count: u32,
	attributes:   Vertex_Attribute_Set,
	indices:      Maybe(Pool_Subbuffer(u32)),
	record:       Pool_Subbuffer(Mesh_Record_Data),
	data:         Pool_Subbuffer(u8),
}

@(private = "file")
Pending_Free :: struct {
	retire_value: u64,
	indices:      Maybe(Pool_Subbuffer(u32)),
	record:       Pool_Subbuffer(Mesh_Record_Data),
	data:         Pool_Subbuffer(byte),
}

@(private = "file")
MESH_INDICES_USAGE :: Resource_Usage {
	stages = {.INDEX_INPUT},
	access = {.INDEX_READ},
}

@(private = "file")
MESH_DATA_USAGE :: Resource_Usage {
	stages = {.VERTEX_SHADER},
	access = {.SHADER_STORAGE_READ},
}

@(private = "file")
MESH_RECORD_USAGE :: Resource_Usage {
	stages = {.VERTEX_SHADER},
	access = {.SHADER_STORAGE_READ},
}

@(require_results)
meshes_init :: proc(
	meshes: ^Meshes,
	device: Device,
	mesh_pool_capacity: Device_Size,
	index_pool_capacity: Device_Size,
	allocator := context.allocator,
) -> (
	err: Buffer_Error,
) {
	meshes^ = {}
	defer if err != nil {
		meshes_destroy(meshes, device)
	}

	pool_init(
		&meshes.mesh_pool,
		device,
		capacity = mesh_pool_capacity,
		buffer_usage = {.STORAGE_BUFFER, .TRANSFER_DST, .SHADER_DEVICE_ADDRESS},
	) or_return

	pool_init(
		&meshes.index_pool,
		device,
		capacity = index_pool_capacity,
		buffer_usage = {.INDEX_BUFFER, .TRANSFER_DST},
	) or_return

	handle_map.dynamic_init(&meshes.handle_map, allocator)
	queue.init(&meshes.pending_frees, queue.DEFAULT_CAPACITY, allocator)
	return
}

meshes_destroy :: proc(meshes: ^Meshes, device: Device) {
	meshes_destroy_pending(meshes, max(u64))
	handle_map.dynamic_destroy(&meshes.handle_map)
	queue.destroy(&meshes.pending_frees)
	pool_destroy(&meshes.mesh_pool, device)
	pool_destroy(&meshes.index_pool, device)
	meshes^ = {}
}

@(require_results)
meshes_reserve :: proc(meshes: ^Meshes) -> Mesh_Handle {
	return handle_map.add(&meshes.handle_map, {loaded = false})
}

@(require_results)
meshes_add :: proc(
	meshes: ^Meshes,
	upload_queue: ^Upload_Queue,
	frame_ring: Frame_Ring,
	mesh: Mesh,
) -> (
	handle: Mesh_Handle,
	err: Mesh_Error,
) {
	handle = meshes_reserve(meshes)
	if err = meshes_replace(meshes, upload_queue, frame_ring, handle, mesh); err != nil {
		meshes_remove(meshes, frame_ring, handle)
		return {}, err
	}
	return handle, nil
}

meshes_replace :: proc(
	meshes: ^Meshes,
	upload_queue: ^Upload_Queue,
	frame_ring: Frame_Ring,
	handle: Mesh_Handle,
	mesh: Mesh,
) -> (
	err: Mesh_Error,
) {
	slot, ok := handle_map.get(&meshes.handle_map, handle)
	if !ok {
		return .Invalid_Handle
	}

	new_slot := allocate_mesh(meshes, mesh) or_return
	if err = upload_mesh(meshes, upload_queue, frame_ring, new_slot, mesh); err != nil {
		defer_free(meshes, frame_ring, new_slot)
		return err
	}

	defer_free(meshes, frame_ring, slot^)
	new_slot.handle = slot.handle
	slot^ = new_slot
	return nil
}

@(private = "file", require_results)
allocate_mesh :: proc(meshes: ^Meshes, mesh: Mesh) -> (slot: Mesh_Slot, err: Mesh_Error) {
	mesh_validate(mesh) or_return

	// Allocate mesh subbuffers
	size := 0
	for _, attribute in mesh.attributes {
		size += mesh_attribute_size(mesh, attribute)
	}

	data, data_ok := pool_make(&meshes.mesh_pool, []u8, size)
	if !data_ok {
		return {}, .Out_Of_Gpu_Memory
	}

	record, record_ok := pool_new(&meshes.mesh_pool, Mesh_Record_Data)
	if !record_ok {
		pool_free(&meshes.mesh_pool, &data)
		return {}, .Out_Of_Gpu_Memory
	}

	index_count := 0
	indices: Maybe(Pool_Subbuffer(u32))
	if mesh.indices != nil {
		switch indices in mesh.indices {
		case []u16:
			index_count = len(indices)
		case []u32:
			index_count = len(indices)
		}

		indices_ok: bool
		indices, indices_ok = pool_make(
			&meshes.index_pool,
			[]u32,
			index_count,
			alignment = size_of(u32),
		)
		if !indices_ok {
			pool_free(&meshes.mesh_pool, &record)
			pool_free(&meshes.mesh_pool, &data)
			return {}, .Out_Of_Gpu_Memory
		}
	}

	return {
			loaded = true,
			index_count = u32(index_count),
			vertex_count = u32(mesh.vertex_count),
			attributes = mesh_attribute_set(mesh),
			indices = indices,
			record = record,
			data = data,
		},
		nil
}

@(private = "file", require_results)
upload_mesh :: proc(
	meshes: ^Meshes,
	upload_queue: ^Upload_Queue,
	frame_ring: Frame_Ring,
	slot: Mesh_Slot,
	mesh: Mesh,
) -> (
	err: Mesh_Error,
) {
	if mesh.indices != nil {
		staging_indices, staging_indices_ok := upload_subbuffer_reserve(
			upload_queue,
			frame_ring,
			slot.indices.?,
			slot.indices.?.count,
			MESH_INDICES_USAGE,
		)
		if !staging_indices_ok {
			return .Out_Of_Staging_Memory
		}

		switch indices in mesh.indices {
		case []u16:
			for index, i in indices {
				staging_indices[i] = u32(index)
			}
		case []u32:
			copy(staging_indices, indices)
		}
	}

	staging_data, staging_data_ok := upload_subbuffer_reserve(
		upload_queue,
		frame_ring,
		slot.data,
		slot.data.count,
		MESH_DATA_USAGE,
	)
	if !staging_data_ok {
		return .Out_Of_Staging_Memory
	}

	offset := 0
	data_offsets := [Vertex_Attribute]u32{}
	data_encodings := [Vertex_Attribute]u8{}
	data_divisors := [Vertex_Attribute]u32{}
	for attribute_data, attribute in mesh.attributes {
		attribute_data := attribute_data.? or_continue
		data_offsets[attribute] = u32(offset)
		data_encodings[attribute] = u8(attribute_data.encoding)
		data_divisors[attribute] = u32(
			1 if attribute_data.divisor == nil else attribute_data.divisor.?,
		)
		attribute_size := mesh_attribute_size(mesh, attribute)
		copy(staging_data[offset:], attribute_data.data[:attribute_size])
		offset += attribute_size
	}

	staging_record, staging_record_ok := upload_subbuffer_reserve(
		upload_queue,
		frame_ring,
		slot.record,
		1,
		MESH_RECORD_USAGE,
	)
	if !staging_record_ok {
		return .Out_Of_Staging_Memory
	}
	staging_record[0] = {
		data_address = slot.data.address,
		data_offsets = data_offsets,
		encodings    = data_encodings,
		divisors     = data_divisors,
		attributes   = slot.attributes,
		vertex_count = u32(mesh.vertex_count),
	}

	return nil
}

meshes_remove :: proc(meshes: ^Meshes, frame_ring: Frame_Ring, handle: Mesh_Handle) {
	if slot, ok := handle_map.get(&meshes.handle_map, handle); ok {
		defer_free(meshes, frame_ring, slot^)
		handle_map.remove(&meshes.handle_map, handle)
	}
}

@(private = "file")
defer_free :: proc(meshes: ^Meshes, frame_ring: Frame_Ring, slot: Mesh_Slot) {
	if slot.loaded {
		queue.enqueue(
			&meshes.pending_frees,
			{
				retire_value = frame_ring.timeline_value + 1,
				indices = slot.indices,
				record = slot.record,
				data = slot.data,
			},
		)
	}
}

@(require_results)
meshes_get_index_buffer :: proc(meshes: Meshes) -> Buffer {
	return meshes.index_pool.buffer
}

@(require_results)
meshes_get_info :: proc(meshes: ^Meshes, handle: Mesh_Handle) -> (Mesh_Info, bool) {
	if slot, ok := handle_map.get(&meshes.handle_map, handle); ok && slot.loaded {
		first_index := u32(0)
		if indices, indices_ok := slot.indices.?; indices_ok {
			assert(indices.offset % size_of(u32) == 0)
			first_index = u32(indices.offset / size_of(u32))
		}
		return {
				first_index = first_index,
				index_count = slot.index_count,
				vertex_count = slot.vertex_count,
				attributes = slot.attributes,
				record_address = slot.record.address,
			},
			true
	}
	return {}, false
}

@(require_results)
meshes_is_indexed :: proc(meshes: ^Meshes, handle: Mesh_Handle) -> bool {
	if slot, ok := handle_map.get(&meshes.handle_map, handle); ok {
		return slot.indices != nil
	}
	return false
}

@(require_results)
meshes_is_loaded :: proc(meshes: ^Meshes, handle: Mesh_Handle) -> bool {
	if slot, ok := handle_map.get(&meshes.handle_map, handle); ok {
		return slot.loaded
	}
	return false
}

meshes_destroy_pending :: proc(meshes: ^Meshes, finished_value: u64) {
	for queue.len(meshes.pending_frees) > 0 {
		pending_free := queue.front_ptr(&meshes.pending_frees)
		if pending_free.retire_value <= finished_value {
			pool_free(&meshes.mesh_pool, &pending_free.record)
			pool_free(&meshes.mesh_pool, &pending_free.data)
			if indices, ok := pending_free.indices.?; ok {
				pool_free(&meshes.index_pool, &indices)
			}
			queue.dequeue(&meshes.pending_frees)
		} else {
			break
		}
	}
}
