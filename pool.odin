package main
import "core:slice"
import vk "vendor:vulkan"
import "third_party/vma"

Pool_Subbuffer :: struct($T: typeid) {
	mapped: []T,
	address: Device_Address,
	offset: Device_Size,
	size: Device_Size,
	buffer_handle: vk.Buffer,
	allocation_handle: vma.VirtualAllocation,
}

Pool_Buffer :: struct {
	buffer: Buffer,
	block: vma.VirtualBlock,
}

pool_init :: proc(
	pool: ^Pool_Buffer, 
	device: Device, 
	#any_int capacity: Device_Size,
	buffer_usage: vk.BufferUsageFlags,
	memory_usage: vma.MemoryUsage = .AUTO,
	memory_flags: vma.AllocationCreateFlags = {},
	location := #caller_location,
) -> Buffer_Error {
	assert(pool != nil)
	pool^ = {}

	buffer_init(&pool.buffer, device, capacity, buffer_usage, memory_usage, memory_flags) or_return
	vma.CreateVirtualBlock({size = capacity}, &pool.block)
	return nil
}

pool_destroy :: proc(pool: ^Pool_Buffer, device: Device) {
	if pool == nil {
		return
	}

	vma.ClearVirtualBlock(pool.block)
	vma.DestroyVirtualBlock(pool.block)
	buffer_destroy(&pool.buffer, device)
	pool^ = {}
}

@(private="file")
pool_allocate :: proc(
	pool: ^Pool_Buffer, 
	size: Device_Size, 
	alignment: Device_Size,
) -> (allocation: vma.VirtualAllocation, offset: Device_Size, ok: bool) {
	result := vma.VirtualAllocate(
		pool.block, 
		{size = size, alignment = alignment}, 
		&allocation, 
		&offset,
	)

	if result != .SUCCESS {
		ok = false
		return
	}

	return allocation, offset, true
	
}

pool_make :: proc(
	pool: ^Pool_Buffer, 
	$T: typeid/[]$E, 
	#any_int count: int,
	#any_int alignment := 0,
) -> (Pool_Subbuffer(E), bool) {
	size := Device_Size(size_of(E) * count)
	align := Device_Size(max(align_of(E), alignment))
	allocation, offset, ok := pool_allocate(pool, size, align)
	if !ok {
		return {}, false
	}
	
	address := 0 if pool.buffer.address == 0 else pool.buffer.address + Device_Address(offset)
	mapped := nil if pool.buffer.mapped == nil else pool.buffer.mapped[int(offset):][:int(size)]
	return {
		mapped = slice.reinterpret([]E, mapped),	
		address = address,
		offset = offset,
		size = size,
		allocation_handle = allocation,
		buffer_handle = pool.buffer.handle,
	}, true
}

pool_new :: proc(
	pool: ^Pool_Buffer, 
	$T: typeid, 
	#any_int alignment := 0,
) -> (Pool_Subbuffer(T), bool) {
	return pool_make(pool, []T, 1, alignment)
}

pool_free :: proc(pool: ^Pool_Buffer, subbuffer: ^Pool_Subbuffer($E)) {
	assert(pool != nil)
	assert(pool.buffer.handle == subbuffer.buffer_handle)
	vma.VirtualFree(pool.block, subbuffer.allocation_handle)
	subbuffer^ = {}
}
