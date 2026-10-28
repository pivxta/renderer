package main
import "core:slice"
import vk "vendor:vulkan"

Staging_Allocator :: struct {
	ring: Timeline_Ring,
	buffer: Buffer,
	alignment: Device_Size,
}

Staging_Memory :: struct {
	data: []byte,
	offset: Device_Size,
	buffer_handle: vk.Buffer,
}

@(require_results)
staging_init :: proc(
	s: ^Staging_Allocator, 
	device: Device, 
	capacity: Device_Size,
) -> (err: Buffer_Error) {
	assert(s != nil)

	defer if err != nil {
		staging_destroy(s, device)
	}

	s.alignment = max(device.properties.limits.optimalBufferCopyOffsetAlignment, 32)
	tring_init(&s.ring, u64(capacity))
	buffer_init(
		&s.buffer, device,
		size = capacity,
		buffer_usage = {.TRANSFER_SRC},
		memory_flags = {.MAPPED, .HOST_ACCESS_SEQUENTIAL_WRITE},
	) or_return

	return nil
}

staging_destroy :: proc(s: ^Staging_Allocator, device: Device) {
	if s == nil {
		return
	}

	buffer_destroy(&s.buffer, device)
	tring_destroy(&s.ring)
	s^ = {}
}

staging_retire :: proc(s: ^Staging_Allocator, value: u64) {
	assert(s != nil)
	tring_retire(&s.ring, value)
}

@(require_results)
staging_flush :: proc(s: ^Staging_Allocator, device: Device) -> Buffer_Error {
	assert(s != nil)
	for block in tring_pending_blocks(s.ring) {
		if block.end > block.start {
			buffer_flush(&s.buffer, device, block.start, block.end - block.start) or_return
		}
	}
	tring_commit(&s.ring)
	return nil
}

@(private="file")
staging_allocate_bytes :: proc(
	allocator: ^Staging_Allocator, 
	frame_ring: Frame_Ring,
	size: Device_Size, 
) -> (data: []byte, offset: Device_Size, ok: bool) {
	allocation, has := tring_allocate_with(
		&allocator.ring, 
		frame_ring.timeline_value + 1,
		u64(size), 
		u64(allocator.alignment),
	)

	if !has {
		return
	}

	offset = Device_Size(allocation.offset)
	data = allocator.buffer.mapped[allocation.offset:][:allocation.size]
	return data, offset, true
}

@(require_results)
staging_make :: proc(
	allocator: ^Staging_Allocator,
	frame_ring: Frame_Ring,
	$T: typeid/[]$E,
	#any_int count: int,
) -> (result: Staging_Memory, ok: bool) {
	assert(count >= 0)
	if count == 0 {
		return {}, true
	}

	bytes, offset := staging_allocate_bytes(
		allocator, 
		frame_ring, 
		Device_Size(count * size_of(E)),
	) or_return

	return {
		buffer_handle = allocator.buffer.handle,
		data = slice.reinterpret([]E, bytes), 
		offset = offset,
	}, true
}

@(require_results)
staging_slice_clone :: proc(
	allocator: ^Staging_Allocator, 
	frame_ring: Frame_Ring,
	src: []$E,
) -> (result: Staging_Memory, ok: bool) {
	result = staging_make(allocator, frame_ring, []E, len(src)) or_return
	copy(slice.reinterpret([]E, result.data), src)
	return result, true
}

@(require_results)
staging_slice_size :: proc(s: Staging_Memory) -> Device_Size {
	return Device_Size(slice.size(s.data))
}

