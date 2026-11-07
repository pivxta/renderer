package main
import "core:slice"
import vk "vendor:vulkan"

Staging_Buffer :: struct {
	ring: Timeline_Ring,
	buffer: Buffer,
	alignment: Device_Size,
}

Staging_Subbuffer :: struct($T: typeid) {
	data: []T,
	offset: Device_Size,
	buffer_handle: vk.Buffer,
}

@(require_results)
staging_init :: proc(
	staging: ^Staging_Buffer, 
	device: Device, 
	capacity: Device_Size,
) -> (err: Buffer_Error) {
	assert(staging != nil)

	defer if err != nil {
		staging_destroy(staging, device)
	}

	staging.alignment = max(device.properties.limits.optimalBufferCopyOffsetAlignment, 32)
	tring_init(&staging.ring, u64(capacity))
	buffer_init(
		&staging.buffer, device,
		size = capacity,
		buffer_usage = {.TRANSFER_SRC},
		memory_flags = {.MAPPED, .HOST_ACCESS_SEQUENTIAL_WRITE},
	) or_return

	return nil
}

staging_destroy :: proc(staging: ^Staging_Buffer, device: Device) {
	if staging == nil {
		return
	}

	buffer_destroy(&staging.buffer, device)
	tring_destroy(&staging.ring)
	staging^ = {}
}

staging_retire :: proc(staging: ^Staging_Buffer, value: u64) {
	assert(staging != nil)
	tring_retire(&staging.ring, value)
}

@(require_results)
staging_flush :: proc(staging: ^Staging_Buffer, device: Device) -> Buffer_Error {
	assert(staging != nil)
	for block in tring_pending_blocks(staging.ring) {
		if block.end > block.start {
			buffer_flush(&staging.buffer, device, block.start, block.end - block.start) or_return
		}
	}
	tring_commit(&staging.ring)
	return nil
}

@(private="file")
staging_allocate_bytes :: proc(
	staging: ^Staging_Buffer, 
	frame_ring: Frame_Ring,
	size: Device_Size, 
) -> (data: []byte, offset: Device_Size, ok: bool) {
	allocation, has := tring_allocate_with(
		&staging.ring, 
		frame_ring.timeline_value + 1,
		u64(size), 
		u64(staging.alignment),
	)

	if !has {
		return
	}

	offset = Device_Size(allocation.offset)
	data = staging.buffer.mapped[allocation.offset:][:allocation.size]
	return data, offset, true
}

@(require_results)
staging_make :: proc(
	staging: ^Staging_Buffer,
	frame_ring: Frame_Ring,
	$T: typeid/[]$E,
	#any_int count: int,
) -> (result: Staging_Subbuffer(E), ok: bool) {
	assert(count >= 0)
	if count == 0 {
		return {
			buffer_handle = staging.buffer.handle,
			offset = 0,
			data = nil,
		}, true
	}

	bytes, offset := staging_allocate_bytes(
		staging, 
		frame_ring, 
		Device_Size(count * size_of(E)),
	) or_return

	return {
		buffer_handle = staging.buffer.handle,
		data = slice.reinterpret([]E, bytes), 
		offset = offset,
	}, true
}

@(require_results)
staging_slice_clone :: proc(
	staging: ^Staging_Buffer, 
	frame_ring: Frame_Ring,
	src: []$E,
) -> (result: Staging_Subbuffer(E), ok: bool) {
	result = staging_make(staging, frame_ring, []E, len(src)) or_return
	copy(slice.reinterpret([]E, result.data), src)
	return result, true
}

@(require_results)
staging_subbuffer_size :: proc(staging: Staging_Subbuffer($E)) -> Device_Size {
	return Device_Size(slice.size(staging.data))
}

