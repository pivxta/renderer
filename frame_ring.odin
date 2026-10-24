package main
import vk "vendor:vulkan"

FRAMES_IN_FLIGHT :: 2

Frame_Ring :: struct {
	command_pool: vk.CommandPool,
	quick_command_buffer: vk.CommandBuffer,
	command_buffers: [FRAMES_IN_FLIGHT]vk.CommandBuffer,
	available_semaphores: [FRAMES_IN_FLIGHT]vk.Semaphore,
	timeline_semaphore: vk.Semaphore,
	timeline_value: u64,
	frame_counter: u64,
}
