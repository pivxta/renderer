package main
import "base:runtime"
import "core:log"
import "core:strings"
import "vendor:glfw"
import vk "vendor:vulkan"

MAX_FRAMES_IN_FLIGHT :: 2

REQUIRED_DEVICE_EXTS_VK12 := []cstring {
	vk.KHR_DYNAMIC_RENDERING_EXTENSION_NAME,
	vk.KHR_SYNCHRONIZATION_2_EXTENSION_NAME,
}

Renderer :: struct {
	instance: vk.Instance,
	debug_messenger: vk.DebugUtilsMessengerEXT,
	messenger_context: ^runtime.Context,

	physical_device: vk.PhysicalDevice,
	device: vk.Device,
	graphics_queue: vk.Queue,
	graphics_queue_family: u32,
	device_properties: vk.PhysicalDeviceProperties,

	window: glfw.WindowHandle,
	surface: vk.SurfaceKHR,
	swapchain: vk.SwapchainKHR,
	swapchain_images: []vk.Image,
	swapchain_views: []vk.ImageView,
	swapchain_extent: vk.Extent2D,
	swapchain_format: vk.Format,
	swapchain_colorspace: vk.ColorSpaceKHR,

	command_pool: vk.CommandPool,
	command_buffers: [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,

	fences: [MAX_FRAMES_IN_FLIGHT]vk.Fence,
	image_available: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore,
	image_presentable: [dynamic]vk.Semaphore,
	current_frame: int,

	pipeline_layout: vk.PipelineLayout,
	pipeline: vk.Pipeline,
}

Surface_Capabilities :: struct {
	caps: vk.SurfaceCapabilitiesKHR,
	formats: []vk.SurfaceFormatKHR,
	present_modes: []vk.PresentModeKHR,
}

renderer_init :: proc(r: ^Renderer, window: glfw.WindowHandle) {
	create_instance(r)
	create_surface(r, window)
	pick_physical_device(r)
	create_device_and_queues(r)
	configure_swapchain(r)
	create_command_buffers(r)
	create_sync_primitives(r)
	create_pipeline(r)
}

renderer_destroy :: proc (r: ^Renderer) {
	must(vk.DeviceWaitIdle(r.device))
	destroy_pipeline(r)
	destroy_sync_primitives(r)
	destroy_command_pool(r)
	destroy_swapchain(r)
	vk.DestroyDevice(r.device, nil)
	vk.DestroySurfaceKHR(r.instance, r.surface, nil)
	vk.DestroyDebugUtilsMessengerEXT(r.instance, r.debug_messenger, nil)
	vk.DestroyInstance(r.instance, nil)
	log.destroy_console_logger(r.messenger_context.logger)
	free(r.messenger_context)
	r^ = {}
}

renderer_draw :: proc(r: ^Renderer) {
	must(vk.WaitForFences(r.device, 1, &r.fences[r.current_frame], true, max(u64)))

	image_index: u32
	acquisition_result := vk.AcquireNextImageKHR(
		r.device, r.swapchain, max(u64),
		r.image_available[r.current_frame], 0,
		&image_index,
	)

	#partial switch acquisition_result {
	case .SUCCESS, .SUBOPTIMAL_KHR:
	case .ERROR_OUT_OF_DATE_KHR:
		configure_swapchain(r)
		return
	case:
		log.panicf("Failed to acquire next image: %v", acquisition_result)
	}

	must(vk.ResetFences(r.device, 1, &r.fences[r.current_frame]))

	command_buffer := begin_command_buffer(r)
	record_commands(r, command_buffer, image_index)
	submit_command_buffer(r, command_buffer, image_index)

	present_info := vk.PresentInfoKHR {
		sType = .PRESENT_INFO_KHR,
		pSwapchains = &r.swapchain,
		swapchainCount = 1,
		pWaitSemaphores = &r.image_presentable[image_index],
		waitSemaphoreCount = 1,
		pImageIndices = &image_index,
	}
	present_result := vk.QueuePresentKHR(r.graphics_queue, &present_info)
	#partial switch present_result {
	case .SUCCESS:
	case .ERROR_OUT_OF_DATE_KHR, .SUBOPTIMAL_KHR:
		configure_swapchain(r)
	case:	
		log.panicf("Failed to present image: %v", present_result)
	}

	r.current_frame = (r.current_frame + 1) % MAX_FRAMES_IN_FLIGHT
}

record_draw_commands :: proc(r: ^Renderer, cmd: vk.CommandBuffer, image_index: u32) {
	attachment_info := vk.RenderingAttachmentInfo {
		sType = .RENDERING_ATTACHMENT_INFO,
		imageView = r.swapchain_views[image_index],
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
			extent = r.swapchain_extent,
		},
		layerCount = 1,
		colorAttachmentCount = 1,
		pColorAttachments = &attachment_info,
	}

	vk.CmdBeginRendering(cmd, &render_info)

	viewport := swapchain_get_full_viewport(r)
	vk.CmdSetViewport(cmd, 0, 1, &viewport)

	scissor := swapchain_get_full_area(r)
	vk.CmdSetScissor(cmd, 0, 1, &scissor)

	vk.CmdBindPipeline(cmd, .GRAPHICS, r.pipeline)
	vk.CmdDraw(cmd, 3, 1, 0, 0)
	
	vk.CmdEndRendering(cmd)
}

record_commands :: proc(r: ^Renderer, cmd: vk.CommandBuffer, image_index: u32) {
	subresource_range := vk.ImageSubresourceRange {
		aspectMask = {.COLOR},
		baseMipLevel = 0,
		levelCount = 1,
		baseArrayLayer = 0,
		layerCount = 1,
	}

	record_image_barrier(r, cmd, {
		image = r.swapchain_images[image_index],
		srcStageMask = {},
		srcAccessMask = {},
		dstStageMask = {.COLOR_ATTACHMENT_OUTPUT},
		dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
		oldLayout = .UNDEFINED,
		newLayout = .COLOR_ATTACHMENT_OPTIMAL,
		subresourceRange = subresource_range,
	})
	record_draw_commands(r, cmd, image_index)
	record_image_barrier(r, cmd, {
		image = r.swapchain_images[image_index],
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

submit_command_buffer :: proc(r: ^Renderer, command_buffer: vk.CommandBuffer, image_index: u32) {
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
		semaphore = r.image_presentable[image_index],
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
	must(vk.QueueSubmit2(r.graphics_queue, 1, &submit_info, r.fences[r.current_frame]))
}

SHADER_SPIRV :: #load("shaders/compiled/default.spv")

create_pipeline :: proc(r: ^Renderer) {
	layout_info := vk.PipelineLayoutCreateInfo {
		sType = .PIPELINE_LAYOUT_CREATE_INFO,
	}

	must(vk.CreatePipelineLayout(r.device, &layout_info, nil, &r.pipeline_layout))

	shader_module: vk.ShaderModule
	shader_module_info := vk.ShaderModuleCreateInfo {
		sType = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(SHADER_SPIRV),
		pCode = cast([^]u32)raw_data(SHADER_SPIRV),
	}

	must(vk.CreateShaderModule(r.device, &shader_module_info, nil, &shader_module))

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

	color_attachment_format := r.swapchain_format
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

	must(vk.CreateGraphicsPipelines(r.device, 0, 1, &pipeline_info, nil, &r.pipeline))
	vk.DestroyShaderModule(r.device, shader_module, nil)
}

destroy_pipeline :: proc(r: ^Renderer) {
	vk.DestroyPipelineLayout(r.device, r.pipeline_layout, nil)
	vk.DestroyPipeline(r.device, r.pipeline, nil)
}

create_command_buffers :: proc(r: ^Renderer) {
	pool_info := vk.CommandPoolCreateInfo {
		sType = .COMMAND_POOL_CREATE_INFO,
		flags = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = r.graphics_queue_family,
	}

	must(vk.CreateCommandPool(r.device, &pool_info, nil, &r.command_pool))

	alloc_info := vk.CommandBufferAllocateInfo {
		sType = .COMMAND_BUFFER_ALLOCATE_INFO,
		level = .PRIMARY,
		commandBufferCount = MAX_FRAMES_IN_FLIGHT,
		commandPool = r.command_pool,
	}

	must(vk.AllocateCommandBuffers(r.device, &alloc_info, raw_data(r.command_buffers[:])))
}

destroy_command_pool :: proc(r: ^Renderer) {
	vk.DestroyCommandPool(r.device, r.command_pool, nil)
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
		must(vk.CreateSemaphore(r.device, &semaphore_info, nil, &r.image_available[i]))
		must(vk.CreateFence(r.device, &fence_info, nil, &r.fences[i]))
	}
}

destroy_sync_primitives :: proc(r: ^Renderer) {
	for i in 0..<MAX_FRAMES_IN_FLIGHT {
		vk.DestroySemaphore(r.device, r.image_available[i], nil)	
		vk.DestroyFence(r.device, r.fences[i], nil)	
	}
}

create_instance :: proc (r: ^Renderer) {
	vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))

	app_info := vk.ApplicationInfo {
		sType = .APPLICATION_INFO,
		applicationVersion = vk.MAKE_VERSION(1, 0, 0),
		engineVersion = vk.MAKE_VERSION(1, 0, 0),
		apiVersion = vk.API_VERSION_1_3,
	}

	// Instance extensions
	req_instance_exts := make([dynamic]cstring, 0, allocator=context.temp_allocator)
	append(&req_instance_exts, ..glfw.GetRequiredInstanceExtensions())
	append(&req_instance_exts, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)

	instance_exts := make([dynamic]cstring, 0, allocator=context.temp_allocator)

	instance_ext_prop_count: u32 
	vk.EnumerateInstanceExtensionProperties(nil, &instance_ext_prop_count, nil)
	instance_ext_props := make(
		[]vk.ExtensionProperties, 
		instance_ext_prop_count, 
		allocator=context.temp_allocator,
	)
	vk.EnumerateInstanceExtensionProperties(nil, &instance_ext_prop_count, raw_data(instance_ext_props))

	outer: for req_ext in req_instance_exts {
		for &instance_ext_prop in instance_ext_props {
			if req_ext == cstring(raw_data(instance_ext_prop.extensionName[:])) {
				append(&instance_exts, req_ext)
				continue outer
			}
		}
		log.panicf("required extension '%v' not available", req_ext)
	}

	// Instance layers
	layers := make([dynamic]cstring, 0, allocator=context.temp_allocator)

	layer_prop_count: u32 
	vk.EnumerateInstanceLayerProperties(&layer_prop_count, nil)
	layer_props := make([]vk.LayerProperties, layer_prop_count, allocator=context.temp_allocator)
	vk.EnumerateInstanceLayerProperties(&layer_prop_count, raw_data(layer_props))

	for &layer_prop in layer_props {
		if bytes_to_string(layer_prop.layerName[:]) == "VK_LAYER_KHRONOS_validation" {
			log.debug("Vulkan validation layers enabled")
			append(&layers, "VK_LAYER_KHRONOS_validation")		  
		}
	}
	
	// Instance creation
	instance_info := vk.InstanceCreateInfo {
		sType = .INSTANCE_CREATE_INFO,
		pApplicationInfo = &app_info,
		enabledExtensionCount = u32(len(instance_exts)),
		ppEnabledExtensionNames = raw_data(instance_exts),
		enabledLayerCount = u32(len(layers)),
		ppEnabledLayerNames = raw_data(layers),
	}

	severity: vk.DebugUtilsMessageSeverityFlagsEXT
	if context.logger.lowest_level <= .Error {
		severity |= {.ERROR}
	}
	if context.logger.lowest_level <= .Warning {
		severity |= {.WARNING}
	}

	r.messenger_context = new_clone(runtime.default_context())
	r.messenger_context.logger = log.create_console_logger(
		lowest=context.logger.lowest_level,
		opt=context.logger.options & {.Level, .Date, .Time, .Terminal_Color},
		ident="Vulkan",
	)

	debug_messenger_info := vk.DebugUtilsMessengerCreateInfoEXT {
		sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
		messageSeverity = severity,
		messageType = {.GENERAL, .VALIDATION, .PERFORMANCE},
		pfnUserCallback = messenger_callback,
		pUserData = r.messenger_context,
	}
	instance_info.pNext = &debug_messenger_info

	must(vk.CreateInstance(&instance_info, nil, &r.instance))
	vk.load_proc_addresses_instance(r.instance)
	must(vk.CreateDebugUtilsMessengerEXT(
		r.instance, 
		&debug_messenger_info, nil, 
		&r.debug_messenger,
	))
}

create_surface :: proc(r: ^Renderer, window: glfw.WindowHandle) {
	r.window = window
	must(glfw.CreateWindowSurface(r.instance, r.window, nil, &r.surface))
}

pick_physical_device :: proc(r: ^Renderer) {
	physical_device_count: u32
	must(vk.EnumeratePhysicalDevices(r.instance, &physical_device_count, nil))
	physical_devices := make(
		[]vk.PhysicalDevice, 
		physical_device_count, 
		allocator=context.temp_allocator,
	)
	must(vk.EnumeratePhysicalDevices(r.instance, &physical_device_count, raw_data(physical_devices)))

	physical_device: vk.PhysicalDevice
	device_properties: vk.PhysicalDeviceProperties
	graphics_queue_family: u32
	picked_score := min(int)

	device_type_names := [vk.PhysicalDeviceType]string {
		.OTHER = "",
		.INTEGRATED_GPU = "integrated ",
		.DISCRETE_GPU = "GPU ",
		.VIRTUAL_GPU = "virtual ",
		.CPU = "CPU ",
	}

	device_scores := [vk.PhysicalDeviceType]int {
		.INTEGRATED_GPU = 4000000,
		.DISCRETE_GPU = 3000000,
		.VIRTUAL_GPU = 2000000,
		.CPU = 1000000,
		.OTHER = 0,
	}

	device_loop: for current_device in physical_devices {
		properties: vk.PhysicalDeviceProperties
		vk.GetPhysicalDeviceProperties(current_device, &properties)

		name := bytes_to_string(properties.deviceName[:])

		log.debugf(
			"[%v] Found %vdevice with API v%v.%v.%v", 
			name,
			device_type_names[properties.deviceType],
			vk.VERSION_MAJOR(properties.apiVersion),
			vk.VERSION_MINOR(properties.apiVersion),
			vk.VERSION_PATCH(properties.apiVersion),
		)

		// Check API version
		if properties.apiVersion < vk.API_VERSION_1_2 {
			log.debugf("[%v] Device rejected: unsupported API version", name)
			continue
		}

		required_device_exts := make([dynamic]cstring, 0, allocator=context.temp_allocator)

		append(&required_device_exts, vk.KHR_SWAPCHAIN_EXTENSION_NAME)
		if properties.apiVersion < vk.API_VERSION_1_3 {
			append(&required_device_exts, ..REQUIRED_DEVICE_EXTS_VK12)		   
		}
		
		ext_props_count: u32
		must(vk.EnumerateDeviceExtensionProperties(current_device, nil, &ext_props_count, nil))
		ext_props := make([]vk.ExtensionProperties, ext_props_count, allocator=context.temp_allocator)
		must(vk.EnumerateDeviceExtensionProperties(current_device, nil, &ext_props_count, raw_data(ext_props)))

		// Check device extensions
		ext_loop: for required_ext in required_device_exts {
			for &ext_prop in ext_props {
				if bytes_to_string(ext_prop.extensionName[:]) == string(required_ext) { 
					continue ext_loop
				}
			}
			log.debugf("[%v] Device rejected: missing extension '%v'", name, required_ext)
			continue device_loop
		}

		// Check queue families
		family_count: u32
		vk.GetPhysicalDeviceQueueFamilyProperties(current_device, &family_count, nil)
		family_props := make([]vk.QueueFamilyProperties, family_count, allocator=context.temp_allocator)
		vk.GetPhysicalDeviceQueueFamilyProperties(current_device, &family_count, raw_data(family_props)) 
		current_graphics_family: u32 
		found_graphics_family := false
		for family_prop, i in family_props { 
			if .GRAPHICS not_in family_prop.queueFlags { 
				continue 
			} 

			supported: b32 
			vk.GetPhysicalDeviceSurfaceSupportKHR(current_device, u32(i), r.surface, &supported) 
			if !supported { 
				continue 
			}

			found_graphics_family = true
			current_graphics_family = u32(i)
			break
		}
		
		if !found_graphics_family {
			log.debugf("[%v] Device rejected: no suitable graphics queue family found", name)
			continue
		}
		
		// Score device
		current_score := device_scores[properties.deviceType]
		current_score += int(properties.limits.maxImageDimension2D)
		log.debugf("[%v] Scored %v", name, current_score)

		if current_score > picked_score {
			picked_score = current_score
			device_properties = properties
			physical_device = current_device
			graphics_queue_family = current_graphics_family
		}
	}

	if physical_device == nil {
		log.panic("No suitable device found")
	}

	r.physical_device = physical_device
	r.device_properties = device_properties
	r.graphics_queue_family = graphics_queue_family

	log.infof(
		"Selected %vdevice '%v', Vulkan API version %v.%v.%v", 
		device_type_names[device_properties.deviceType],
		bytes_to_string(device_properties.deviceName[:]),
		vk.VERSION_MAJOR(device_properties.apiVersion),
		vk.VERSION_MINOR(device_properties.apiVersion),
		vk.VERSION_PATCH(device_properties.apiVersion),
	)
}

create_device_and_queues :: proc(r: ^Renderer) {
	queue_create_infos := []vk.DeviceQueueCreateInfo {
		{
			sType = .DEVICE_QUEUE_CREATE_INFO,
			queueFamilyIndex = r.graphics_queue_family,
			queueCount = 1,
			pQueuePriorities = raw_data([]f32{1}),
		},
	}

	device_features := vk.PhysicalDeviceFeatures {
		imageCubeArray = true,
		samplerAnisotropy = true,
		multiDrawIndirect = true,
	}

	device_features_vk11 := vk.PhysicalDeviceVulkan11Features {
		sType = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, 
		pNext = nil,
		shaderDrawParameters = true,
	}

	device_features_vk12 := vk.PhysicalDeviceVulkan12Features {
		sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, 
		pNext = &device_features_vk11,
		drawIndirectCount = true,
		scalarBlockLayout = true,
		bufferDeviceAddress = true,
		descriptorIndexing = true,
		runtimeDescriptorArray = true,
		descriptorBindingPartiallyBound = true,
		descriptorBindingSampledImageUpdateAfterBind = true,
		shaderSampledImageArrayNonUniformIndexing = true,
	}

	device_features_vk13 := vk.PhysicalDeviceVulkan13Features {
		sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, 
		pNext = &device_features_vk12,
		dynamicRendering = true,
		synchronization2 = true,
	}
	
	dyn_rendering_features := vk.PhysicalDeviceDynamicRenderingFeaturesKHR {
		sType = .PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES_KHR,
		pNext = &device_features_vk12,
		dynamicRendering = true,
	}

	sync2_features := vk.PhysicalDeviceSynchronization2FeaturesKHR {
		sType = .PHYSICAL_DEVICE_SYNCHRONIZATION_2_FEATURES_KHR,
		pNext = &dyn_rendering_features,
		synchronization2 = true,
	}

	device_features_extra: rawptr
	if r.device_properties.apiVersion >= vk.API_VERSION_1_3 {
		device_features_extra = rawptr(&device_features_vk13)
	} else {
		device_features_extra = rawptr(&sync2_features)
	}

	device_exts := [dynamic; 8]cstring{}
	append(&device_exts, vk.KHR_SWAPCHAIN_EXTENSION_NAME)
	if r.device_properties.apiVersion < vk.API_VERSION_1_3 {
		append(&device_exts, ..REQUIRED_DEVICE_EXTS_VK12)
	}

	device_info := vk.DeviceCreateInfo {
		sType = .DEVICE_CREATE_INFO, 
		queueCreateInfoCount = u32(len(queue_create_infos)),
		pQueueCreateInfos = raw_data(queue_create_infos),
		enabledExtensionCount = u32(len(device_exts)),
		ppEnabledExtensionNames = raw_data(device_exts[:]),
		pEnabledFeatures = &device_features,
		pNext = device_features_extra,
	}

	must(vk.CreateDevice(r.physical_device, &device_info, nil, &r.device))
	vk.load_proc_addresses_device(r.device)
	vk.GetDeviceQueue(r.device, r.graphics_queue_family, 0, &r.graphics_queue)
}

swapchain_get_full_area :: proc(r: ^Renderer) -> vk.Rect2D {
	return {
		offset = {0, 0},
		extent = r.swapchain_extent,
	}
}

swapchain_get_full_viewport :: proc(r: ^Renderer) -> vk.Viewport {
	return {
		x = 0.0, 
		y = 0.0,
		width = f32(r.swapchain_extent.width),
		height = f32(r.swapchain_extent.height),
		minDepth = 0.0, 
		maxDepth = 1.0,
	}
}

configure_swapchain :: proc(r: ^Renderer) {
	caps, result := query_surface_capabilities(r, allocator=context.temp_allocator)
	if result != .SUCCESS {
		log.panic("Failed to query surface capabilities")
	}

	extent := pick_extent(caps.caps, r.window)
	format := pick_format(caps.formats)
	present_mode := pick_present_mode(caps.present_modes)
	min_image_count := pick_min_image_count(caps.caps)

	swapchain_info := vk.SwapchainCreateInfoKHR {
		sType = .SWAPCHAIN_CREATE_INFO_KHR,
		surface = r.surface,
		minImageCount = min_image_count, 
		presentMode = present_mode,
		imageFormat = format.format,
		imageColorSpace = format.colorSpace,
		imageExtent = extent,
		imageArrayLayers = 1,
		imageUsage = {.COLOR_ATTACHMENT},
		preTransform = caps.caps.currentTransform,
		compositeAlpha = {.OPAQUE},
		clipped = true,
		oldSwapchain = r.swapchain,
	}

	swapchain: vk.SwapchainKHR 
	must(vk.DeviceWaitIdle(r.device))
	must(vk.CreateSwapchainKHR(r.device, &swapchain_info, nil, &swapchain))

	destroy_swapchain_textures(r)
	if r.swapchain != 0 {
		vk.DestroySwapchainKHR(r.device, r.swapchain, nil)
	}
	if r.swapchain_images != nil {
		delete(r.swapchain_images)
	}

	r.swapchain = swapchain
	r.swapchain_extent = extent
	r.swapchain_format = format.format
	r.swapchain_colorspace = format.colorSpace

	image_count: u32
	must(vk.GetSwapchainImagesKHR(r.device, r.swapchain, &image_count, nil))
	r.swapchain_images = make([]vk.Image, image_count)
	must(vk.GetSwapchainImagesKHR(r.device, r.swapchain, &image_count, raw_data(r.swapchain_images)))

	r.swapchain_views = make([]vk.ImageView, image_count)
	for image, i in r.swapchain_images {
		view_ci := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = image,
			viewType = .D2,
			format = r.swapchain_format,
			subresourceRange = {
				aspectMask = {.COLOR},
				levelCount = 1,
				layerCount = 1,
			},
		}
		must(vk.CreateImageView(r.device, &view_ci, nil, &r.swapchain_views[i]))
	}

	recreate_swapchain_semaphores(r)
}

destroy_swapchain_semaphores :: proc(r: ^Renderer) {
	for semaphore in r.image_presentable {
		if semaphore != 0 {
			vk.DestroySemaphore(r.device, semaphore, nil)
		}
	}
	delete(r.image_presentable)
}

recreate_swapchain_semaphores :: proc(r: ^Renderer) {
	for semaphore in r.image_presentable {
		if semaphore != 0 {
			vk.DestroySemaphore(r.device, semaphore, nil)
		}
	}

	resize(&r.image_presentable, len(r.swapchain_images))
	semaphore_info := vk.SemaphoreCreateInfo { sType = .SEMAPHORE_CREATE_INFO }
	for &semaphore in r.image_presentable {
		must(vk.CreateSemaphore(r.device, &semaphore_info, nil, &semaphore))
	}
}

destroy_swapchain :: proc(r: ^Renderer) {
	destroy_swapchain_semaphores(r)
	destroy_swapchain_textures(r)
	if r.swapchain != 0 {
		vk.DestroySwapchainKHR(r.device, r.swapchain, nil)
	}
}

destroy_swapchain_textures :: proc(r: ^Renderer) {
	for view in r.swapchain_views {
		vk.DestroyImageView(r.device, view, nil)
	}
	if r.swapchain_images != nil {
		delete(r.swapchain_images)
		r.swapchain_images = nil
	}
	if r.swapchain_views != nil {
		delete(r.swapchain_views)
		r.swapchain_views = nil
	}
}

pick_format :: proc(formats: []vk.SurfaceFormatKHR) -> vk.SurfaceFormatKHR {
	for format in formats {
		if (format.format == .B8G8R8A8_SRGB ||
		    format.format == .R8G8B8A8_SRGB) && 
		    format.colorSpace == .SRGB_NONLINEAR {
			return format
		}
	}
	return formats[0]
}

pick_present_mode :: proc(modes: []vk.PresentModeKHR) -> vk.PresentModeKHR {
	for mode in modes {
		if mode == .MAILBOX {
			return mode
		}
	}
	return .FIFO
}

pick_extent :: proc(caps: vk.SurfaceCapabilitiesKHR, window: glfw.WindowHandle) -> vk.Extent2D {
	if caps.currentExtent.width != max(u32) {
		return caps.currentExtent
	}

	width, height := glfw.GetFramebufferSize(window)
	return vk.Extent2D {
		width = clamp(u32(width), caps.minImageExtent.width, caps.maxImageExtent.width),
		height = clamp(u32(height), caps.minImageExtent.height, caps.maxImageExtent.height),
	}
}

pick_min_image_count :: proc(caps: vk.SurfaceCapabilitiesKHR) -> u32 {
	image_count := caps.minImageCount + 1
	if caps.maxImageCount > 0 {
		image_count = min(image_count, caps.maxImageCount)
	}
	return image_count
}

query_surface_capabilities :: proc(r: ^Renderer, allocator := context.allocator) -> (
	caps: Surface_Capabilities,
	result: vk.Result,
) {
	context.allocator = allocator

	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(r.physical_device, r.surface, &caps.caps) or_return
	
	present_mode_count: u32
	vk.GetPhysicalDeviceSurfacePresentModesKHR(
		r.physical_device, 
		r.surface, 
		&present_mode_count, 
		nil,
	) or_return

	caps.present_modes = make([]vk.PresentModeKHR, present_mode_count)
	vk.GetPhysicalDeviceSurfacePresentModesKHR(
		r.physical_device, 
		r.surface, 
		&present_mode_count, 
		raw_data(caps.present_modes),
	) or_return

	format_count: u32
	vk.GetPhysicalDeviceSurfaceFormatsKHR(
		r.physical_device, 
		r.surface, 
		&format_count, 
		nil,
	) or_return

	caps.formats = make([]vk.SurfaceFormatKHR, format_count)
	vk.GetPhysicalDeviceSurfaceFormatsKHR(
		r.physical_device, 
		r.surface, 
		&format_count, 
		raw_data(caps.formats),
	) or_return

	return
}

destroy_surface_capabilites :: proc(caps: ^Surface_Capabilities) {
	delete(caps.formats)
	delete(caps.present_modes)
}

messenger_callback :: proc "system" (
	severity: vk.DebugUtilsMessageSeverityFlagsEXT,
	types: vk.DebugUtilsMessageTypeFlagsEXT,
	callback_data: ^vk.DebugUtilsMessengerCallbackDataEXT,
	user_data: rawptr,
) -> b32 {
	context = (cast(^runtime.Context)user_data)^
	
	level: log.Level
	if .ERROR in severity {
		level = .Error
	} else if .WARNING in severity {
		level = .Warning
	} else if .INFO in severity {
		level = .Info
	} else {
		level = .Debug
	}

	log.logf(level, "%s", callback_data.pMessage)
	return false
}

must :: proc(result: vk.Result, location := #caller_location) {
	if result != .SUCCESS {
		log.panicf("Fatal Vulkan error: %v", result, location=location)
	}
}

bytes_to_string :: proc(bytes: []byte) -> string {
	return strings.truncate_to_byte(string(bytes), 0)
}


