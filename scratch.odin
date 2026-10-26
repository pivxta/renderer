package main
import "core:slice"
import vk "vendor:vulkan"

MINIMUM_SCRATCH_ALIGNMENT :: 16

Scratch_Buffer :: struct {
	buffer: Buffer,
	ring: Timeline_Ring,
}

Scratch_Ptr :: struct($T: typeid) {
	data: ^T,
	offset: Device_Size,
	address: Device_Address,
	buffer_handle: vk.Buffer,
}

Scratch_Slice :: struct($T: typeid) {
	data: []T,
	offset: Device_Size,
	address: Device_Address,
	buffer_handle: vk.Buffer,
}

@(require_results)
scratch_init :: proc(
	s: ^Scratch_Buffer, 
	device: Device, 
	capacity: Device_Size,
) -> Buffer_Error {
	assert(s != nil)

	tring_init(&s.ring, u64(capacity))
	buffer_init(
		&s.buffer, device,
		size = capacity,
		buffer_usage = {.SHADER_DEVICE_ADDRESS, .STORAGE_BUFFER},
		memory_flags = {.MAPPED, .HOST_ACCESS_SEQUENTIAL_WRITE},
	) or_return

	return nil
}

scratch_destroy :: proc(s: ^Scratch_Buffer, device: Device) {
	if s == nil {
		return
	}

	buffer_destroy(&s.buffer, device)
	tring_destroy(&s.ring)
	s^ = {}
}

scratch_begin :: proc(s: ^Scratch_Buffer, value: u64) {
	assert(s != nil)
	tring_begin(&s.ring, value)
}

scratch_commit :: proc(s: ^Scratch_Buffer) {
	assert(s != nil)
	tring_commit(&s.ring)
}

scratch_retire :: proc(s: ^Scratch_Buffer, value: u64) {
	assert(s != nil)
	tring_retire(&s.ring, value)
}

@(require_results)
scratch_flush :: proc(s: ^Scratch_Buffer, device: Device) -> Buffer_Error {
	assert(s != nil)
	for block in tring_pending_blocks(s.ring) {
		if block.end > block.start {
			buffer_flush(&s.buffer, device, block.start, block.end - block.start) or_return
		}
	}
	return nil
}

@(private="file")
scratch_allocate_bytes :: proc(
	s: ^Scratch_Buffer, 
	size: Device_Size, 
	alignment: Device_Size,
) -> (data: []byte, offset: Device_Size, ok: bool) {
	allocation, has := tring_allocate(
		&s.ring, 
		u64(size), 
		u64(max(alignment, MINIMUM_SCRATCH_ALIGNMENT)),
	)
	if !has {
		return
	}

	offset = Device_Size(allocation.offset)
	data = s.buffer.mapped[allocation.offset:][:allocation.size]
	return data, offset, true
}

@(require_results)
scratch_make :: proc(
	s: ^Scratch_Buffer,
	$T: typeid/[]$E,
	#any_int count: int,
	alignment := 0,
	zeroed := true,
) -> (result: Scratch_Slice(E), ok: bool) {
	assert(count >= 0)
	if count == 0 {
		return {}, true
	}

	size := Device_Size(count * size_of(E))
	align := Device_Size(alignment if alignment > 0 else align_of(E))
	bytes, offset := scratch_allocate_bytes(s, size, align) or_return
	if zeroed {
		slice.zero(bytes)
	}

	return Scratch_Slice(E) {
		buffer_handle = s.buffer.handle,
		address = s.buffer.address + Device_Address(offset),
		data = slice.reinterpret([]E, bytes),
		offset = offset,
	}, true
}

@(require_results)
scratch_new :: proc(
	s: ^Scratch_Buffer,
	$T: typeid,
	alignment := 0,
	zeroed := true,
) -> (result: Scratch_Ptr(T), ok: bool) {
	single := scratch_make(s, []T, 1, alignment, zeroed) or_return
	return Scratch_Ptr(T) {
		data = &single.data[0],
		offset = single.offset,
		address = single.address,
		buffer_handle = single.buffer_handle,
	}, true
}

@(require_results)
scratch_new_clone :: proc(
	s: ^Scratch_Buffer,
	value: $T,
	alignment := 0,
) -> (result: Scratch_Ptr(T), ok: bool) {
	result = scratch_new(s, T, alignment, zeroed = false) or_return
	result.data^ = value
	return result, true
}

@(require_results)
scratch_slice_clone :: proc(
	s: ^Scratch_Buffer,
	src: []$E,
	alignment := 0,
) -> (result: Scratch_Slice(E), ok: bool) {
	result = scratch_make(s, []E, len(src), alignment, zeroed = false) or_return
	copy(result.data, src)
	return result, true
}

scratch_slice_size :: proc(s: Scratch_Slice($E)) -> Device_Size {
	return Device_Size(slice.size(s.data))
}
