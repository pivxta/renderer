package main
import "core:slice"
import "core:math/bits"
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

@(require_results)
pool_init :: proc(
	pool: ^Pool_Buffer, 
	device: Device, 
	#any_int capacity: Device_Size,
	buffer_usage: vk.BufferUsageFlags,
	memory_usage: vma.MemoryUsage = .AUTO,
	memory_flags: vma.AllocationCreateFlags = {},
	location := #caller_location,
) -> (err: Buffer_Error) {
	assert(pool != nil)
	pool^ = {}

	defer if err != nil {
		pool_destroy(pool, device)
	}

	buffer_init(&pool.buffer, device, capacity, buffer_usage, memory_usage, memory_flags) or_return
	vma.CreateVirtualBlock({size = capacity}, &pool.block) or_return
	return nil
}

pool_destroy :: proc(pool: ^Pool_Buffer, device: Device) {
	if pool == nil {
		return
	}

	if pool.block != nil {
		vma.ClearVirtualBlock(pool.block)
		vma.DestroyVirtualBlock(pool.block)
	}

	buffer_destroy(&pool.buffer, device)
	pool^ = {}
}

@(private="file")
pool_allocate :: proc(
	pool: ^Pool_Buffer, 
	size: Device_Size, 
	alignment: Device_Size,
) -> (allocation: vma.VirtualAllocation, offset: Device_Size, ok: bool) {
	assert(bits.is_power_of_two(u64(alignment)))

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

@(require_results)
pool_make :: proc(
	pool: ^Pool_Buffer, 
	$T: typeid/[]$E, 
	#any_int count: int,
	#any_int alignment := 0,
) -> (Pool_Subbuffer(E), bool) {
	assert(pool != nil)
	assert(count >= 0)

	if count == 0 {
		return {}, true
	}

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

@(require_results)
pool_new :: proc(
	pool: ^Pool_Buffer, 
	$T: typeid, 
	#any_int alignment := 0,
) -> (Pool_Subbuffer(T), bool) {
	return pool_make(pool, []T, 1, alignment)
}

pool_free :: proc(pool: ^Pool_Buffer, subbuffer: ^Pool_Subbuffer($E)) {
	assert(pool != nil)
	if subbuffer.allocation_handle == 0 {
		return
	}

	assert(pool.buffer.handle == subbuffer.buffer_handle)
	vma.VirtualFree(pool.block, subbuffer.allocation_handle)
	subbuffer^ = {}
}

@(require_results)
pool_subbuffer_flush :: proc(
	subbuffer: ^Pool_Subbuffer, 
	device: Device, 
	#any_int offset: Device_Size = 0,
	#any_int size: Device_Size = 0,
) -> Buffer_Error {
}
