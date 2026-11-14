package main
import vk "vendor:vulkan"

Surface :: struct {
	window:                 ^Window,
	surface:                vk.SurfaceKHR,
	swapchain:              vk.SwapchainKHR,
	textures:               []Texture,
	extent:                 vk.Extent2D,
	format:                 vk.Format,
	colorspace:             vk.ColorSpaceKHR,
	presentable_semaphores: []vk.Semaphore,
}

Surface_Texture :: struct {
	index:       u32,
	texture:     ^Texture,
	presentable: vk.Semaphore,
}

Surface_Configure_Error :: enum {
	None = 0,
	No_Surface_Formats,
	No_Present_Modes,
}

Surface_Error :: union #shared_nil {
	Surface_Configure_Error,
	Texture_Error,
	vk.Result,
}

@(private = "file")
Surface_Capabilities :: struct {
	caps:          vk.SurfaceCapabilitiesKHR,
	formats:       []vk.SurfaceFormatKHR,
	present_modes: []vk.PresentModeKHR,
}

@(require_results)
surface_init :: proc(surface: ^Surface, instance: Instance, window: ^Window) -> Surface_Error {
	surface.window = window
	surface.surface = window_create_surface(window, instance) or_return
	return nil
}

surface_destroy :: proc(surface: ^Surface, instance: Instance, device: Device) {
	destroy_swapchain_semaphores(&surface.presentable_semaphores, device)
	destroy_swapchain_textures(&surface.textures, device)
	destroy_swapchain(&surface.swapchain, device)
	if surface.surface != 0 {
		vk.DestroySurfaceKHR(instance.handle, surface.surface, nil)
	}

	surface^ = {}
}

@(require_results)
surface_should_resize :: proc(surface: Surface) -> bool {
	return surface.window.resized
}

@(require_results)
surface_present :: proc(surface: Surface, device: Device, texture: Surface_Texture) -> vk.Result {
	swapchain := surface.swapchain
	semaphore := texture.presentable
	index := texture.index
	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		pSwapchains        = &swapchain,
		swapchainCount     = 1,
		pWaitSemaphores    = &semaphore,
		waitSemaphoreCount = 1,
		pImageIndices      = &index,
	}
	return vk.QueuePresentKHR(device.graphics_queue, &present_info)
}

@(require_results)
surface_acquire_texture :: proc(
	surface: Surface,
	device: Device,
	available: vk.Semaphore,
) -> (
	texture: Surface_Texture,
	result: vk.Result,
) {
	index: u32
	result = vk.AcquireNextImageKHR(
		device.logical,
		surface.swapchain,
		max(u64),
		available,
		0,
		&index,
	)

	if result != .SUCCESS && result != .SUBOPTIMAL_KHR {
		return
	}

	texture = {
		index       = index,
		texture     = &surface.textures[index],
		presentable = surface.presentable_semaphores[index],
	}

	return
}

@(require_results)
surface_configure :: proc(surface: ^Surface, device: Device) -> (err: Surface_Error) {
	caps := query_surface_capabilities(surface^, device) or_return
	if len(caps.formats) == 0 {
		return Surface_Configure_Error.No_Surface_Formats
	}
	if len(caps.present_modes) == 0 {
		return Surface_Configure_Error.No_Present_Modes
	}

	extent, ok := pick_extent(caps.caps, surface.window)
	if !ok {
		return nil
	}

	format := pick_format(caps.formats)
	present_mode := pick_present_mode(caps.present_modes)
	min_image_count := pick_min_image_count(caps.caps)

	swapchain_info := vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = surface.surface,
		minImageCount    = min_image_count,
		presentMode      = present_mode,
		imageFormat      = format.format,
		imageColorSpace  = format.colorSpace,
		imageExtent      = extent,
		imageArrayLayers = 1,
		imageUsage       = {.COLOR_ATTACHMENT},
		preTransform     = caps.caps.currentTransform,
		compositeAlpha   = {.OPAQUE},
		clipped          = true,
		oldSwapchain     = surface.swapchain,
	}

	swapchain: vk.SwapchainKHR
	vk.CreateSwapchainKHR(device.logical, &swapchain_info, nil, &swapchain) or_return
	defer if err != nil {
		destroy_swapchain(&surface.swapchain, device)
	}

	textures := create_swapchain_textures(device, swapchain, format.format, extent) or_return
	defer if err != nil {
		destroy_swapchain_textures(&textures, device)
	}

	semaphores := create_swapchain_semaphores(device, len(textures)) or_return
	defer if err != nil {
		destroy_swapchain_semaphores(&semaphores, device)
	}

	destroy_swapchain(&surface.swapchain, device)
	destroy_swapchain_textures(&surface.textures, device)
	destroy_swapchain_semaphores(&surface.presentable_semaphores, device)

	surface.swapchain = swapchain
	surface.extent = extent
	surface.format = format.format
	surface.colorspace = format.colorSpace
	surface.textures = textures
	surface.presentable_semaphores = semaphores
	return nil
}

@(private = "file")
destroy_swapchain :: proc(swapchain: ^vk.SwapchainKHR, device: Device) {
	if swapchain^ != 0 {
		vk.DestroySwapchainKHR(device.logical, swapchain^, nil)
		swapchain^ = 0
	}
}

@(private = "file")
create_swapchain_textures :: proc(
	device: Device,
	swapchain: vk.SwapchainKHR,
	format: vk.Format,
	extent: vk.Extent2D,
) -> (
	textures: []Texture,
	err: Texture_Error,
) {
	image_count: u32
	vk.GetSwapchainImagesKHR(device.logical, swapchain, &image_count, nil) or_return
	images := make([]vk.Image, image_count, context.temp_allocator)
	vk.GetSwapchainImagesKHR(device.logical, swapchain, &image_count, raw_data(images)) or_return

	textures = make([]Texture, image_count)
	defer if err != nil {
		destroy_swapchain_textures(&textures, device)
	}

	for image, n in images {
		texture_wrap(
			&textures[n],
			device,
			image = image,
			type = .D2,
			format = format,
			extent = {extent.width, extent.height, 1},
			usage = {.COLOR_ATTACHMENT},
		) or_return
	}

	return
}

@(private = "file")
destroy_swapchain_textures :: proc(textures: ^[]Texture, device: Device) {
	for &texture in textures {
		texture_destroy(&texture, device)
	}
	if textures != nil {
		delete(textures^)
		textures^ = nil
	}
}

@(private = "file")
create_swapchain_semaphores :: proc(device: Device, count: int) -> ([]vk.Semaphore, vk.Result) {
	semaphores := make([]vk.Semaphore, count)

	semaphore_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	for &semaphore in semaphores {
		if result := vk.CreateSemaphore(device.logical, &semaphore_info, nil, &semaphore);
		   result != .SUCCESS {
			destroy_swapchain_semaphores(&semaphores, device)
			return nil, result
		}
	}

	return semaphores, .SUCCESS
}

@(private = "file")
destroy_swapchain_semaphores :: proc(semaphores: ^[]vk.Semaphore, d: Device) {
	for semaphore in semaphores {
		if semaphore != 0 {
			vk.DestroySemaphore(d.logical, semaphore, nil)
		}
	}
	delete(semaphores^)
	semaphores^ = nil
}

@(private = "file")
pick_format :: proc(formats: []vk.SurfaceFormatKHR) -> vk.SurfaceFormatKHR {
	for format in formats {
		if (format.format == .B8G8R8A8_SRGB || format.format == .R8G8B8A8_SRGB) &&
		   format.colorSpace == .SRGB_NONLINEAR {
			return format
		}
	}
	return formats[0]
}

@(private = "file")
pick_present_mode :: proc(modes: []vk.PresentModeKHR) -> vk.PresentModeKHR {
	for mode in modes {
		if mode == .MAILBOX {
			return mode
		}
	}
	return .FIFO
}

@(private = "file")
pick_extent :: proc(caps: vk.SurfaceCapabilitiesKHR, window: ^Window) -> (vk.Extent2D, bool) {
	extent := caps.currentExtent
	if extent.width == max(u32) {
		width, height := window_get_framebuffer_size(window)
		extent = {
			width  = clamp(
				u32(max(width, 0)),
				caps.minImageExtent.width,
				caps.maxImageExtent.width,
			),
			height = clamp(
				u32(max(height, 0)),
				caps.minImageExtent.height,
				caps.maxImageExtent.height,
			),
		}
	}

	if extent.width == 0 || extent.height == 0 {
		return {}, false
	}

	return extent, true
}

@(private = "file")
pick_min_image_count :: proc(caps: vk.SurfaceCapabilitiesKHR) -> u32 {
	image_count := caps.minImageCount + 1
	if caps.maxImageCount > 0 {
		image_count = min(image_count, caps.maxImageCount)
	}
	return image_count
}

@(private = "file")
query_surface_capabilities :: proc(
	surface: Surface,
	device: Device,
	allocator := context.temp_allocator,
) -> (
	caps: Surface_Capabilities,
	result: vk.Result,
) {
	context.allocator = allocator

	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(
		device.physical,
		surface.surface,
		&caps.caps,
	) or_return

	present_mode_count: u32
	vk.GetPhysicalDeviceSurfacePresentModesKHR(
		device.physical,
		surface.surface,
		&present_mode_count,
		nil,
	) or_return

	caps.present_modes = make([]vk.PresentModeKHR, present_mode_count)
	vk.GetPhysicalDeviceSurfacePresentModesKHR(
		device.physical,
		surface.surface,
		&present_mode_count,
		raw_data(caps.present_modes),
	) or_return

	format_count: u32
	vk.GetPhysicalDeviceSurfaceFormatsKHR(
		device.physical,
		surface.surface,
		&format_count,
		nil,
	) or_return

	caps.formats = make([]vk.SurfaceFormatKHR, format_count)
	vk.GetPhysicalDeviceSurfaceFormatsKHR(
		device.physical,
		surface.surface,
		&format_count,
		raw_data(caps.formats),
	) or_return

	return
}
