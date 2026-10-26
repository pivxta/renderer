package main
import "core:container/queue"
import "core:math/bits"

Timeline_Ring_Range :: struct {
	retire_value: u64,
	logical_offset: u64,
	size: u64,
}

Timeline_Ring_Allocation :: struct {
	offset: u64,
	size: u64,
}

Timeline_Ring_Block :: struct {
	start: u64,
	end: u64,
}

Timeline_Ring :: struct {
	capacity: u64,
	committed_head: u64,
	logical_tail: u64,
	logical_head: u64,

	current_value: u64,
	committed_value: u64,
	retired_value: u64,
	committed_ranges: queue.Queue(Timeline_Ring_Range),
}

tring_init :: proc(ring: ^Timeline_Ring, capacity: u64) {
	assert(ring != nil)

	COMMITTED_QUEUE_CAPACITY :: 128

	ring^ = {}
	ring.capacity = capacity
	queue.init(&ring.committed_ranges, COMMITTED_QUEUE_CAPACITY)
}

tring_destroy :: proc(ring: ^Timeline_Ring) {
	if ring == nil {
		return
	}

	queue.destroy(&ring.committed_ranges)
	ring^ = {}
}

tring_allocate :: proc(
	ring: ^Timeline_Ring, 
	size: u64, 
	alignment: u64,
) -> (alloc: Timeline_Ring_Allocation, ok: bool) {
	assert(ring != nil)

	assert(size > 0)
	assert(bits.is_power_of_two(alignment), "alignment must be a power of two")

	if size > ring.capacity {
		return
	}

	head := ring.logical_head % ring.capacity
	offset := (head + alignment - 1) & ~(alignment - 1)
	if offset + size > ring.capacity {
		offset = 0
	}

	skipped := offset - head if offset >= head else ring.capacity - head
	total := skipped + size
	used := ring.logical_head - ring.logical_tail
	if used + total > ring.capacity {
		return
	}

	ring.logical_head += total
	alloc.offset = offset
	alloc.size = size
	return alloc, true
}

tring_pending_blocks :: proc(ring: Timeline_Ring) -> (ranges: [dynamic; 2]Timeline_Ring_Block) {
	if ring.committed_head == ring.logical_head {
		return
	}

	tail := ring.committed_head % ring.capacity
	head := ring.logical_head % ring.capacity
	if head > tail {
		append(&ranges, {tail, head})	
		return
	}

	append(&ranges, {tail, ring.capacity})
	append(&ranges, {0, head})
	return
}

tring_begin :: proc(ring: ^Timeline_Ring, value: u64) {
	assert(value >= ring.current_value) 
	assert(value > ring.committed_value)
	ring.current_value = value
	ring.logical_head = ring.committed_head
}

tring_commit :: proc(ring: ^Timeline_Ring) {
	assert(ring.current_value > ring.committed_value)
	ring.committed_value = ring.current_value
	if ring.logical_head > ring.committed_head {
		queue.enqueue(&ring.committed_ranges, {
			retire_value = ring.current_value,
			logical_offset = ring.committed_head,
			size = ring.logical_head - ring.committed_head,
		})
		ring.committed_head = ring.logical_head
	}
}

tring_retire :: proc(ring: ^Timeline_Ring, value: u64) {
	assert(value >= ring.retired_value)

	ring.retired_value = value
	for queue.len(ring.committed_ranges) > 0 {
		range := queue.front(&ring.committed_ranges)
		if range.retire_value <= value {
			queue.dequeue(&ring.committed_ranges)
			ring.logical_tail = range.logical_offset + range.size
		} else {
			break
		}
	}
}
