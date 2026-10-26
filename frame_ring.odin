package main
import vk "vendor:vulkan"

MAX_FRAMES_IN_FLIGHT :: 2
SCRATCH_CAPACITY :: 16 * 1024 * 1024

Frame_Ring :: struct {
	scratch: Scratch_Buffer,

	command_pool: vk.CommandPool,
	quick_command_buffer: vk.CommandBuffer,
	command_buffers: [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer, 

	timeline_value: u64,
	timeline_signals: [MAX_FRAMES_IN_FLIGHT]u64,
	timeline: vk.Semaphore,
	image_available: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore,

	frame_counter: u64,
	ring_index: int,
}

Frame_Context :: struct {
	ring_index: int,
	frame_counter: u64,
	image_available: vk.Semaphore,
	command_buffer: vk.CommandBuffer,
	scratch: ^Scratch_Buffer,
}

Frame_Ring_Error :: union #shared_nil {
	Buffer_Error,
	vk.Result,
}

@(require_results)
frame_ring_init :: proc(f: ^Frame_Ring, device: Device) -> (err: Frame_Ring_Error) {
	assert(f != nil)

	f^ = {}

	defer if err != nil {
		frame_ring_destroy(f, device)
	}

	// Create command pool
	pool_info := vk.CommandPoolCreateInfo {
		sType = .COMMAND_POOL_CREATE_INFO,
		flags = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = device.graphics_queue_family,
	}

	vk.CreateCommandPool(device.logical, &pool_info, nil, &f.command_pool) or_return

	// Allocate command buffers
	alloc_info := vk.CommandBufferAllocateInfo {
		sType = .COMMAND_BUFFER_ALLOCATE_INFO,
		level = .PRIMARY,
		commandPool = f.command_pool,
		commandBufferCount = MAX_FRAMES_IN_FLIGHT,
	}

	vk.AllocateCommandBuffers(
		device.logical, 
		&alloc_info, 
		raw_data(f.command_buffers[:]),
	) or_return

	quick_alloc_info := vk.CommandBufferAllocateInfo {
		sType = .COMMAND_BUFFER_ALLOCATE_INFO,
		level = .PRIMARY,
		commandPool = f.command_pool,
		commandBufferCount = 1,
	}

	vk.AllocateCommandBuffers(
		device.logical, 
		&quick_alloc_info, 
		&f.quick_command_buffer,
	) or_return

	// Create timeline semaphore
	timeline_type_info := vk.SemaphoreTypeCreateInfo {
		sType = .SEMAPHORE_TYPE_CREATE_INFO,
		semaphoreType = .TIMELINE,
		initialValue = 0,
	}
	timeline_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
		pNext = &timeline_type_info,
	}
	vk.CreateSemaphore(device.logical, &timeline_info, nil, &f.timeline) or_return

	// Create image semaphores
	semaphore_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	for i in 0..<MAX_FRAMES_IN_FLIGHT {
		vk.CreateSemaphore(device.logical, &semaphore_info, nil, &f.image_available[i]) or_return
	}

	// Create scratch buffer
	scratch_init(&f.scratch, device, SCRATCH_CAPACITY) or_return

	return
}

frame_ring_destroy :: proc(f: ^Frame_Ring, device: Device) {
	if f == nil {
		return
	}

	scratch_destroy(&f.scratch, device)

	if f.command_pool != 0 {
		vk.DestroyCommandPool(device.logical, f.command_pool, nil)
		f.command_pool = 0
	}

	f.quick_command_buffer = nil
	for i in 0..<MAX_FRAMES_IN_FLIGHT {
		f.command_buffers[i] = nil 
	}

	if f.timeline != 0 {
		vk.DestroySemaphore(device.logical, f.timeline, nil)	
		f.timeline = 0
	}

	for i in 0..<MAX_FRAMES_IN_FLIGHT {
		if f.image_available[i] != 0 {
			vk.DestroySemaphore(device.logical, f.image_available[i], nil)	
			f.image_available[i] = 0
		}
	}
}

@(require_results)
frame_begin :: proc(f: ^Frame_Ring, device: Device) -> (
	ctx: Frame_Context, 
	err: Frame_Ring_Error,
) {
	// Wait for the previous frame in the same ring position to finish
	timeline_semaphore := f.timeline
	timeline_signal := f.timeline_signals[f.ring_index]
	wait_info := vk.SemaphoreWaitInfo {
		sType = .SEMAPHORE_WAIT_INFO,
		semaphoreCount = 1,
		pSemaphores = &timeline_semaphore,
		pValues = &timeline_signal,
	}
	vk.WaitSemaphores(device.logical, &wait_info, max(u64)) or_return

	// Setup scratch buffer
	current_value: u64
	vk.GetSemaphoreCounterValue(device.logical, f.timeline, &current_value) or_return 
	scratch_retire(&f.scratch, current_value)
	scratch_begin(&f.scratch, f.timeline_value + 1)

	// Begin command buffer
	command_buffer := f.command_buffers[f.ring_index]
	vk.ResetCommandBuffer(command_buffer, {}) or_return
	vk.BeginCommandBuffer(command_buffer, &vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}) or_return

	ctx.command_buffer = command_buffer
	ctx.image_available = f.image_available[f.ring_index]
	ctx.frame_counter = f.frame_counter
	ctx.ring_index = f.ring_index
	ctx.scratch = &f.scratch
	return
}

@(require_results)
frame_submit :: proc(
	f: ^Frame_Ring, 
	device: Device, 
	signal: vk.Semaphore,
	frame: Frame_Context, 
) -> Frame_Ring_Error {
	assert(f != nil)
	assert(frame.frame_counter == f.frame_counter)
	assert(frame.ring_index == f.ring_index)

	scratch_flush(&f.scratch, device) or_return

	command_buffer := f.command_buffers[f.ring_index]
	vk.EndCommandBuffer(command_buffer) or_return

	signal_value := f.timeline_value + 1
	image_available := f.image_available[f.ring_index]
	cmd_buffer_info := vk.CommandBufferSubmitInfo {
		sType = .COMMAND_BUFFER_SUBMIT_INFO, 
		commandBuffer = command_buffer,
	}
	wait_info := vk.SemaphoreSubmitInfo {
		sType = .SEMAPHORE_SUBMIT_INFO,
		semaphore = image_available,
		stageMask = {.COLOR_ATTACHMENT_OUTPUT},
	}
	signal_infos := []vk.SemaphoreSubmitInfo {
		{
			sType = .SEMAPHORE_SUBMIT_INFO,
			semaphore = signal,
			stageMask = {.ALL_COMMANDS},
		},
		{
			sType = .SEMAPHORE_SUBMIT_INFO,
			semaphore = f.timeline,
			value = signal_value,
			stageMask = {.ALL_COMMANDS},
		},
	}
	submit_info := vk.SubmitInfo2 {
		sType = .SUBMIT_INFO_2,
		commandBufferInfoCount = 1,
		pCommandBufferInfos = &cmd_buffer_info,
		waitSemaphoreInfoCount = 1,
		pWaitSemaphoreInfos = &wait_info,
		signalSemaphoreInfoCount = u32(len(signal_infos)),
		pSignalSemaphoreInfos = raw_data(signal_infos),
	}

	vk.QueueSubmit2(device.graphics_queue, 1, &submit_info, 0) or_return
	
	scratch_commit(&f.scratch)
	f.timeline_value = signal_value
	f.timeline_signals[f.ring_index] = signal_value
	f.ring_index = (f.ring_index + 1) % MAX_FRAMES_IN_FLIGHT
	f.frame_counter += 1
	return nil
}

@(require_results)
begin_quick_command_buffer :: proc(f: Frame_Ring) -> (
	cmd: vk.CommandBuffer, 
	result: vk.Result,
) {
	vk.ResetCommandBuffer(f.quick_command_buffer, {}) or_return
	vk.BeginCommandBuffer(f.quick_command_buffer, &vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}) or_return

	cmd = f.quick_command_buffer
	return
}

@(require_results)
submit_quick_command_buffer :: proc(f: Frame_Ring, device: Device) -> vk.Result {
	vk.EndCommandBuffer(f.quick_command_buffer) or_return

	cmd_buffer_info := vk.CommandBufferSubmitInfo {
		sType = .COMMAND_BUFFER_SUBMIT_INFO, 
		commandBuffer = f.quick_command_buffer,
	}
	submit_info := vk.SubmitInfo2 {
		sType = .SUBMIT_INFO_2,
		commandBufferInfoCount = 1,
		pCommandBufferInfos = &cmd_buffer_info,
	}

	fence: vk.Fence
	fence_info := vk.FenceCreateInfo{
		sType = .FENCE_CREATE_INFO,
	}
	vk.CreateFence(device.logical, &fence_info, nil, &fence) or_return
	defer vk.DestroyFence(device.logical, fence, nil)
	vk.QueueSubmit2(device.graphics_queue, 1, &submit_info, fence) or_return
	vk.WaitForFences(device.logical, 1, &fence, true, max(u64)) or_return

	return .SUCCESS
}
