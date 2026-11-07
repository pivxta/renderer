package main
import "core:slice"
import vk "vendor:vulkan"

MINIMUM_SCRATCH_ALIGNMENT :: 16

Scratch_Buffer :: struct {
	buffer: Buffer,
	ring: Timeline_Ring,
}

Scratch_Subbuffer :: struct($T: typeid) {
	data: []T,
	offset: Device_Size,
	address: Device_Address,
	buffer_handle: vk.Buffer,
}

@(require_results)
scratch_init :: proc(
	scratch: ^Scratch_Buffer, 
	device: Device, 
	capacity: Device_Size,
) -> (err: Buffer_Error) {
	assert(scratch != nil)

	defer if err != nil {
		scratch_destroy(scratch, device)
	}

	tring_init(&scratch.ring, u64(capacity))
	buffer_init(
		&scratch.buffer, device,
		size = capacity,
		buffer_usage = {.SHADER_DEVICE_ADDRESS, .INDIRECT_BUFFER, .STORAGE_BUFFER},
		memory_flags = {.MAPPED, .HOST_ACCESS_SEQUENTIAL_WRITE},
	) or_return

	return nil
}

scratch_destroy :: proc(scratch: ^Scratch_Buffer, device: Device) {
	if scratch == nil {
		return
	}

	buffer_destroy(&scratch.buffer, device)
	tring_destroy(&scratch.ring)
	scratch^ = {}
}

scratch_begin :: proc(scratch: ^Scratch_Buffer, value: u64) {
	assert(scratch != nil)
	tring_begin(&scratch.ring, value)
}

scratch_commit :: proc(scratch: ^Scratch_Buffer) {
	assert(scratch != nil)
	tring_commit(&scratch.ring)
}

scratch_retire :: proc(scratch: ^Scratch_Buffer, value: u64) {
	assert(scratch != nil)
	tring_retire(&scratch.ring, value)
}

@(require_results)
scratch_flush :: proc(scratch: ^Scratch_Buffer, device: Device) -> Buffer_Error {
	assert(scratch != nil)
	for block in tring_pending_blocks(scratch.ring) {
		if block.end > block.start {
			buffer_flush(&scratch.buffer, device, block.start, block.end - block.start) or_return
		}
	}
	return nil
}

@(private="file")
scratch_allocate_bytes :: proc(
	scratch: ^Scratch_Buffer, 
	size: Device_Size, 
	alignment: Device_Size,
) -> (data: []byte, offset: Device_Size, ok: bool) {
	allocation, has := tring_allocate(
		&scratch.ring, 
		u64(size), 
		u64(max(alignment, MINIMUM_SCRATCH_ALIGNMENT)),
	)
	if !has {
		return
	}

	offset = Device_Size(allocation.offset)
	data = scratch.buffer.mapped[allocation.offset:][:allocation.size]
	return data, offset, true
}

@(require_results)
scratch_make :: proc(
	scratch: ^Scratch_Buffer,
	$T: typeid/[]$E,
	#any_int count: int,
	#any_int alignment := 0,
	zeroed := false,
) -> (result: Scratch_Subbuffer(E), ok: bool) {
	assert(count >= 0)
	if count == 0 {
		return {}, true
	}

	size := Device_Size(count * size_of(E))
	align := Device_Size(alignment if alignment > 0 else align_of(E))
	bytes, offset := scratch_allocate_bytes(scratch, size, align) or_return
	if zeroed {
		slice.zero(bytes)
	}

	return Scratch_Subbuffer(E) {
		buffer_handle = scratch.buffer.handle,
		address = scratch.buffer.address + Device_Address(offset),
		data = slice.reinterpret([]E, bytes),
		offset = offset,
	}, true
}

@(require_results)
scratch_new :: proc(
	scratch: ^Scratch_Buffer,
	$T: typeid,
	#any_int alignment := 0,
	zeroed := false,
) -> (result: Scratch_Subbuffer(T), ok: bool) {
	return scratch_make(scratch, []T, 1, alignment, zeroed)
}

@(require_results)
scratch_new_clone :: proc(
	scratch: ^Scratch_Buffer,
	value: $T,
	#any_int alignment := 0,
) -> (result: Scratch_Subbuffer(T), ok: bool) {
	result = scratch_new(scratch, T, alignment, zeroed = false) or_return
	result.data[0] = value
	return result, true
}

@(require_results)
scratch_slice_clone :: proc(
	scratch: ^Scratch_Buffer,
	src: []$E,
	#any_int alignment := 0,
) -> (result: Scratch_Subbuffer(E), ok: bool) {
	result = scratch_make(scratch, []E, len(src), alignment, zeroed = false) or_return
	copy(result.data, src)
	return result, true
}

scratch_subbuffer_size :: proc(subbuffer: Scratch_Subbuffer($E)) -> Device_Size {
	return Device_Size(slice.size(subbuffer.data))
}
