package main
import "core:log"
import "vendor:glfw"
import vk "vendor:vulkan"

Surface :: struct {
	window: glfw.WindowHandle,
	surface: vk.SurfaceKHR,
	swapchain: vk.SwapchainKHR,
	images: []vk.Image,
	views: []vk.ImageView,
	extent: vk.Extent2D,
	format: vk.Format,
	colorspace: vk.ColorSpaceKHR,
	image_presentable: [dynamic]vk.Semaphore,
}

Surface_Texture :: struct {
	index: u32,
	image: vk.Image,
	view: vk.ImageView,
	presentable: vk.Semaphore,
	extent: vk.Extent2D,
	format: vk.Format,
}

@(private="file")
Surface_Capabilities :: struct {
	caps: vk.SurfaceCapabilitiesKHR,
	formats: []vk.SurfaceFormatKHR,
	present_modes: []vk.PresentModeKHR,
}

surface_init :: proc(s: ^Surface, i: Instance, window: glfw.WindowHandle) {
	s.window = window

	must(glfw.CreateWindowSurface(i.handle, s.window, nil, &s.surface))
}

surface_destroy :: proc(s: ^Surface, i: Instance, d: Device) {
	destroy_swapchain(s, d)
	vk.DestroySurfaceKHR(i.handle, s.surface, nil)
	s^ = {}
}

surface_present :: proc(s: Surface, d: Device, texture: Surface_Texture) -> vk.Result {
	swapchain := s.swapchain
	semaphore := texture.presentable
	index := texture.index
	present_info := vk.PresentInfoKHR {
		sType = .PRESENT_INFO_KHR,
		pSwapchains = &swapchain,
		swapchainCount = 1,
		pWaitSemaphores = &semaphore,
		waitSemaphoreCount = 1,
		pImageIndices = &index,
	}
	return vk.QueuePresentKHR(d.graphics_queue, &present_info)
}

surface_acquire_texture :: proc(s: Surface, d: Device, image_available: vk.Semaphore) -> (
	texture: Surface_Texture,
	result: vk.Result,
) {
	image_index: u32
	result = vk.AcquireNextImageKHR(
		d.logical, s.swapchain, max(u64),
		image_available, 0,
		&image_index,
	)

	if result != .SUCCESS && result != .SUBOPTIMAL_KHR {
		return	
	}

	texture = {
		index = image_index,
		image = s.images[image_index],
		view = s.views[image_index],
		presentable = s.image_presentable[image_index],
		extent = s.extent,
		format = s.format,
	}
	return
}

surface_configure :: proc(s: ^Surface, d: Device) {
	caps, result := query_surface_capabilities(s^, d, context.temp_allocator)
	if result != .SUCCESS {
		log.panic("Failed to query surface capabilities")
	}

	extent := pick_extent(caps.caps, s.window)
	format := pick_format(caps.formats)
	present_mode := pick_present_mode(caps.present_modes)
	min_image_count := pick_min_image_count(caps.caps)

	swapchain_info := vk.SwapchainCreateInfoKHR {
		sType = .SWAPCHAIN_CREATE_INFO_KHR,
		surface = s.surface,
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
		oldSwapchain = s.swapchain,
	}

	swapchain: vk.SwapchainKHR 
	must(vk.DeviceWaitIdle(d.logical))
	must(vk.CreateSwapchainKHR(d.logical, &swapchain_info, nil, &swapchain))

	destroy_swapchain_textures(s, d)
	if s.swapchain != 0 {
		vk.DestroySwapchainKHR(d.logical, s.swapchain, nil)
	}

	s.swapchain = swapchain
	s.extent = extent
	s.format = format.format
	s.colorspace = format.colorSpace

	image_count: u32
	must(vk.GetSwapchainImagesKHR(d.logical, s.swapchain, &image_count, nil))
	s.images = make([]vk.Image, image_count)
	must(vk.GetSwapchainImagesKHR(d.logical, s.swapchain, &image_count, raw_data(s.images)))

	s.views = make([]vk.ImageView, image_count)
	for image, i in s.images {
		view_ci := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = image,
			viewType = .D2,
			format = s.format,
			subresourceRange = {
				aspectMask = {.COLOR},
				levelCount = 1,
				layerCount = 1,
			},
		}
		must(vk.CreateImageView(d.logical, &view_ci, nil, &s.views[i]))
	}

	recreate_swapchain_semaphores(s, d)
}

destroy_swapchain :: proc(s: ^Surface, d: Device) {
	destroy_swapchain_semaphores(s, d)
	destroy_swapchain_textures(s, d)
	if s.swapchain != 0 {
		vk.DestroySwapchainKHR(d.logical, s.swapchain, nil)
	}
}

@(private="file")
destroy_swapchain_semaphores :: proc(s: ^Surface, d: Device) {
	for semaphore in s.image_presentable {
		if semaphore != 0 {
			vk.DestroySemaphore(d.logical, semaphore, nil)
		}
	}
	delete(s.image_presentable)
}

@(private="file")
recreate_swapchain_semaphores :: proc(s: ^Surface, d: Device) {
	for semaphore in s.image_presentable {
		if semaphore != 0 {
			vk.DestroySemaphore(d.logical, semaphore, nil)
		}
	}

	resize(&s.image_presentable, len(s.images))

	semaphore_info := vk.SemaphoreCreateInfo { sType = .SEMAPHORE_CREATE_INFO }
	for &semaphore in s.image_presentable {
		must(vk.CreateSemaphore(d.logical, &semaphore_info, nil, &semaphore))
	}
}

@(private="file")
destroy_swapchain_textures :: proc(s: ^Surface, d: Device) {
	for view in s.views {
		vk.DestroyImageView(d.logical, view, nil)
	}
	if s.images != nil {
		delete(s.images)
		s.images = nil
	}
	if s.views != nil {
		delete(s.views)
		s.views = nil
	}
}

@(private="file")
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

@(private="file")
pick_present_mode :: proc(modes: []vk.PresentModeKHR) -> vk.PresentModeKHR {
	for mode in modes {
		if mode == .MAILBOX {
			return mode
		}
	}
	return .FIFO
}

@(private="file")
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

@(private="file")
pick_min_image_count :: proc(caps: vk.SurfaceCapabilitiesKHR) -> u32 {
	image_count := caps.minImageCount + 1
	if caps.maxImageCount > 0 {
		image_count = min(image_count, caps.maxImageCount)
	}
	return image_count
}

@(private="file")
query_surface_capabilities :: proc(
	s: Surface, 
	d: Device, 
	allocator := context.allocator,
) -> (
	caps: Surface_Capabilities,
	result: vk.Result,
) {
	context.allocator = allocator

	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(d.physical, s.surface, &caps.caps) or_return
	
	present_mode_count: u32
	vk.GetPhysicalDeviceSurfacePresentModesKHR(
		d.physical, 
		s.surface, 
		&present_mode_count, 
		nil,
	) or_return

	caps.present_modes = make([]vk.PresentModeKHR, present_mode_count)
	vk.GetPhysicalDeviceSurfacePresentModesKHR(
		d.physical, 
		s.surface, 
		&present_mode_count, 
		raw_data(caps.present_modes),
	) or_return

	format_count: u32
	vk.GetPhysicalDeviceSurfaceFormatsKHR(
		d.physical, 
		s.surface, 
		&format_count, 
		nil,
	) or_return

	caps.formats = make([]vk.SurfaceFormatKHR, format_count)
	vk.GetPhysicalDeviceSurfaceFormatsKHR(
		d.physical, 
		s.surface, 
		&format_count, 
		raw_data(caps.formats),
	) or_return

	return
}
