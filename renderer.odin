package main
import "core:log"
import "vendor:glfw"
import vk "vendor:vulkan"

MAX_FRAMES_IN_FLIGHT :: 2

Renderer :: struct {
	instance: Instance,
	device: Device,
	surface: Surface,

	command_pool: vk.CommandPool,
	command_buffers: [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,

	fences: [MAX_FRAMES_IN_FLIGHT]vk.Fence,
	image_available: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore,
	current_frame: int,

	pipeline_layout: vk.PipelineLayout,
	pipeline: vk.Pipeline,
}

renderer_init :: proc(r: ^Renderer, window: glfw.WindowHandle) {
	instance_init(&r.instance)
	surface_init(&r.surface, r.instance, window)
	device_init(&r.device, r.instance, r.surface)
	surface_configure(&r.surface, r.device)
	create_command_buffers(r)
	create_sync_primitives(r)
	create_pipeline(r)
}

renderer_destroy :: proc (r: ^Renderer) {
	must(vk.DeviceWaitIdle(r.device.logical))

	destroy_pipeline(r)
	destroy_sync_primitives(r)
	destroy_command_pool(r)
	surface_destroy(&r.surface, r.instance, r.device)
	device_destroy(&r.device)
	instance_destroy(&r.instance)
	r^ = {}
}

renderer_draw :: proc(r: ^Renderer) {
	must(vk.WaitForFences(r.device.logical, 1, &r.fences[r.current_frame], true, max(u64)))

	surface_texture, acquire_result := surface_acquire_texture(
		r.surface, 
		r.device, 
		r.image_available[r.current_frame],
	)
	#partial switch acquire_result {
	case .SUCCESS, .SUBOPTIMAL_KHR:
	case .ERROR_OUT_OF_DATE_KHR:
		surface_configure(&r.surface, r.device)
		return
	case:
		log.panicf("Failed to acquire next image: %v", acquire_result)
	}

	must(vk.ResetFences(r.device.logical, 1, &r.fences[r.current_frame]))

	command_buffer := begin_command_buffer(r)
	record_commands(r, command_buffer, surface_texture)
	submit_command_buffer(r, command_buffer, surface_texture)

	present_result := surface_present(r.surface, r.device, surface_texture)
	#partial switch present_result {
	case .SUCCESS:
	case .ERROR_OUT_OF_DATE_KHR, .SUBOPTIMAL_KHR:
		surface_configure(&r.surface, r.device)
	case:	
		log.panicf("Failed to present image: %v", present_result)
	}

	r.current_frame = (r.current_frame + 1) % MAX_FRAMES_IN_FLIGHT
}

record_draw_commands :: proc(r: ^Renderer, cmd: vk.CommandBuffer, surface_tex: Surface_Texture) {
	attachment_info := vk.RenderingAttachmentInfo {
		sType = .RENDERING_ATTACHMENT_INFO,
		imageView = surface_tex.view,
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		storeOp = .STORE,
		loadOp = .CLEAR,
		clearValue = {
			color = {
				float32 = {0.2, 0.7, 1.0, 1.0},
			},
		},
	}
	render_info := vk.RenderingInfo {
		sType = .RENDERING_INFO,
		renderArea = {
			offset = {0, 0},
			extent = r.surface.extent,
		},
		layerCount = 1,
		colorAttachmentCount = 1,
		pColorAttachments = &attachment_info,
	}

	vk.CmdBeginRendering(cmd, &render_info)

	viewport := vk.Viewport {
		x = 0.0, 
		y = 0.0,
		width = f32(r.surface.extent.width),
		height = f32(r.surface.extent.height),
		minDepth = 0.0, 
		maxDepth = 1.0,
	}
	vk.CmdSetViewport(cmd, 0, 1, &viewport)

	scissor := vk.Rect2D {
		offset = {0, 0},
		extent = r.surface.extent,
	}
	vk.CmdSetScissor(cmd, 0, 1, &scissor)

	vk.CmdBindPipeline(cmd, .GRAPHICS, r.pipeline)
	vk.CmdDraw(cmd, 3, 1, 0, 0)
	
	vk.CmdEndRendering(cmd)
}

record_commands :: proc(r: ^Renderer, cmd: vk.CommandBuffer, surface_tex: Surface_Texture) {
	subresource_range := vk.ImageSubresourceRange {
		aspectMask = {.COLOR},
		baseMipLevel = 0,
		levelCount = 1,
		baseArrayLayer = 0,
		layerCount = 1,
	}

	record_image_barrier(r, cmd, {
		image = surface_tex.image,
		srcStageMask = {},
		srcAccessMask = {},
		dstStageMask = {.COLOR_ATTACHMENT_OUTPUT},
		dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
		oldLayout = .UNDEFINED,
		newLayout = .COLOR_ATTACHMENT_OPTIMAL,
		subresourceRange = subresource_range,
	})
	record_draw_commands(r, cmd, surface_tex)
	record_image_barrier(r, cmd, {
		image = surface_tex.image,
		srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
		srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
		dstStageMask = {},
		dstAccessMask = {},
		oldLayout = .COLOR_ATTACHMENT_OPTIMAL,
		newLayout = .PRESENT_SRC_KHR,
		subresourceRange = subresource_range,
	})
}

record_image_barrier :: proc(r: ^Renderer, cmd: vk.CommandBuffer, barrier: vk.ImageMemoryBarrier2) {
	image_barrier := barrier
	image_barrier.sType = .IMAGE_MEMORY_BARRIER_2
	dependency_info := vk.DependencyInfo {
		sType = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers = &image_barrier,
	}
	vk.CmdPipelineBarrier2(cmd, &dependency_info)
}

begin_command_buffer :: proc(r: ^Renderer) -> vk.CommandBuffer {
	command_buffer := r.command_buffers[r.current_frame]
	must(vk.ResetCommandBuffer(command_buffer, {}))
	must(vk.BeginCommandBuffer(command_buffer, &vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}))
	return command_buffer	
}

submit_command_buffer :: proc(
	r: ^Renderer, 
	command_buffer: vk.CommandBuffer, 
	surface_tex: Surface_Texture,
) {
	must(vk.EndCommandBuffer(command_buffer))
	cmd_buffer_info := vk.CommandBufferSubmitInfo {
		sType = .COMMAND_BUFFER_SUBMIT_INFO, commandBuffer = command_buffer,
	}
	wait_info := vk.SemaphoreSubmitInfo {
		sType = .SEMAPHORE_SUBMIT_INFO,
		semaphore = r.image_available[r.current_frame],
		stageMask = {.COLOR_ATTACHMENT_OUTPUT},
	}
	signal_info := vk.SemaphoreSubmitInfo {
		sType = .SEMAPHORE_SUBMIT_INFO,
		semaphore = surface_tex.presentable,
		stageMask = {.ALL_COMMANDS},
	}
	submit_info := vk.SubmitInfo2 {
		sType = .SUBMIT_INFO_2,
		waitSemaphoreInfoCount = 1,
		pWaitSemaphoreInfos = &wait_info,
		signalSemaphoreInfoCount = 1,
		pSignalSemaphoreInfos = &signal_info,
		commandBufferInfoCount = 1,
		pCommandBufferInfos = &cmd_buffer_info,
	}
	must(vk.QueueSubmit2(r.device.graphics_queue, 1, &submit_info, r.fences[r.current_frame]))
}

SHADER_SPIRV :: #load("shaders/compiled/default.spv")

create_pipeline :: proc(r: ^Renderer) {
	layout_info := vk.PipelineLayoutCreateInfo {
		sType = .PIPELINE_LAYOUT_CREATE_INFO,
	}

	must(vk.CreatePipelineLayout(r.device.logical, &layout_info, nil, &r.pipeline_layout))

	shader_module: vk.ShaderModule
	shader_module_info := vk.ShaderModuleCreateInfo {
		sType = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(SHADER_SPIRV),
		pCode = cast([^]u32)raw_data(SHADER_SPIRV),
	}

	must(vk.CreateShaderModule(r.device.logical, &shader_module_info, nil, &shader_module))

	shader_stages := []vk.PipelineShaderStageCreateInfo {
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.VERTEX},
			module = shader_module,
			pName = "vertex_main",
		},
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.FRAGMENT},
			module = shader_module,
			pName = "fragment_main",
		},
	}

	vertex_state := vk.PipelineVertexInputStateCreateInfo {
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
	}

	input_assembly_state := vk.PipelineInputAssemblyStateCreateInfo {
		sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_LIST,
	}

	raster_state := vk.PipelineRasterizationStateCreateInfo {
		sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		lineWidth = 1,
		polygonMode = .FILL,
		cullMode = {.BACK},
		frontFace = .COUNTER_CLOCKWISE,
	}

	viewport_state := vk.PipelineViewportStateCreateInfo {
		sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount = 1,
	}

	sample_mask := ~vk.SampleMask(0)
	ms_state := vk.PipelineMultisampleStateCreateInfo {
		sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		pSampleMask = &sample_mask,
		rasterizationSamples = {._1},
	}

	blend_attachment := vk.PipelineColorBlendAttachmentState {
		colorWriteMask = {.R, .G, .B, .A},
	}

	blend_state := vk.PipelineColorBlendStateCreateInfo {
		sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments = &blend_attachment,
	}

	dynamic_states := []vk.DynamicState {.VIEWPORT, .SCISSOR}
	dynamic_state := vk.PipelineDynamicStateCreateInfo {
		sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = u32(len(dynamic_states)),
		pDynamicStates = raw_data(dynamic_states),
	}

	color_attachment_format := r.surface.format
	rendering_info := vk.PipelineRenderingCreateInfo {
		sType = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount = 1,
		pColorAttachmentFormats = &color_attachment_format,
	}

	pipeline_info := vk.GraphicsPipelineCreateInfo {
		sType = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext = rawptr(&rendering_info),
		layout = r.pipeline_layout,
		stageCount = 2,
		pStages = raw_data(shader_stages),
		pVertexInputState = &vertex_state,
		pInputAssemblyState = &input_assembly_state,
		pRasterizationState = &raster_state,
		pViewportState = &viewport_state,
		pMultisampleState = &ms_state,
		pColorBlendState = &blend_state,
		pDynamicState = &dynamic_state,
	}

	must(vk.CreateGraphicsPipelines(r.device.logical, 0, 1, &pipeline_info, nil, &r.pipeline))
	vk.DestroyShaderModule(r.device.logical, shader_module, nil)
}

destroy_pipeline :: proc(r: ^Renderer) {
	vk.DestroyPipelineLayout(r.device.logical, r.pipeline_layout, nil)
	vk.DestroyPipeline(r.device.logical, r.pipeline, nil)
}

create_command_buffers :: proc(r: ^Renderer) {
	pool_info := vk.CommandPoolCreateInfo {
		sType = .COMMAND_POOL_CREATE_INFO,
		flags = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = r.device.graphics_queue_family,
	}

	must(vk.CreateCommandPool(r.device.logical, &pool_info, nil, &r.command_pool))

	alloc_info := vk.CommandBufferAllocateInfo {
		sType = .COMMAND_BUFFER_ALLOCATE_INFO,
		level = .PRIMARY,
		commandBufferCount = MAX_FRAMES_IN_FLIGHT,
		commandPool = r.command_pool,
	}

	must(vk.AllocateCommandBuffers(
		r.device.logical, 
		&alloc_info, 
		raw_data(r.command_buffers[:]),
	))
}

destroy_command_pool :: proc(r: ^Renderer) {
	vk.DestroyCommandPool(r.device.logical, r.command_pool, nil)
}

create_sync_primitives :: proc(r: ^Renderer) {
	semaphore_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	fence_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}
	for i in 0..<MAX_FRAMES_IN_FLIGHT {
		must(vk.CreateSemaphore(r.device.logical, &semaphore_info, nil, &r.image_available[i]))
		must(vk.CreateFence(r.device.logical, &fence_info, nil, &r.fences[i]))
	}
}

destroy_sync_primitives :: proc(r: ^Renderer) {
	for i in 0..<MAX_FRAMES_IN_FLIGHT {
		vk.DestroySemaphore(r.device.logical, r.image_available[i], nil)	
		vk.DestroyFence(r.device.logical, r.fences[i], nil)	
	}
}

