package main
import "core:log"
import vk "vendor:vulkan"
import "third_party/vma"

@(private="file")
REQUIRED_DEVICE_EXTS_VK12 := []cstring {
	vk.KHR_DYNAMIC_RENDERING_EXTENSION_NAME,
	vk.KHR_SYNCHRONIZATION_2_EXTENSION_NAME,
}

Device :: struct {
	properties: vk.PhysicalDeviceProperties,
	allocator: vma.Allocator,
	physical: vk.PhysicalDevice,
	logical: vk.Device,
	graphics_queue: vk.Queue,
	graphics_queue_family: u32,
}

device_init :: proc(d: ^Device, i: Instance, s: Surface) {
	pick_physical_device(d, i, s)
	create_device_and_queues(d)
	create_allocator(d, i)
}

device_destroy :: proc(d: ^Device) {
	vma.DestroyAllocator(d.allocator)
	vk.DestroyDevice(d.logical, nil)
	d^ = {}
}

@(private="file")
create_allocator :: proc(d: ^Device, i: Instance) {
	vulkan_functions := vma.create_vulkan_functions()
	create_info: vma.AllocatorCreateInfo = {
		flags            = { .BUFFER_DEVICE_ADDRESS },
		instance         = i.handle,
		physicalDevice   = d.physical,
		device           = d.logical,
		pVulkanFunctions = &vulkan_functions,
		vulkanApiVersion = d.properties.apiVersion,
	}
	vma.CreateAllocator(create_info, &d.allocator)
}

@(private="file")
pick_physical_device :: proc(d: ^Device, i: Instance, s: Surface) {
	physical_device_count: u32
	must(vk.EnumeratePhysicalDevices(i.handle, &physical_device_count, nil))
	physical_devices := make(
		[]vk.PhysicalDevice, 
		physical_device_count, 
		allocator=context.temp_allocator,
	)
	must(vk.EnumeratePhysicalDevices(i.handle, &physical_device_count, raw_data(physical_devices)))

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

		// Check device features
		if !check_device_features(current_device, name, properties.apiVersion) {
			continue device_loop
		}

		// Check queue families
		family_count: u32
		vk.GetPhysicalDeviceQueueFamilyProperties(current_device, &family_count, nil)
		family_props := make([]vk.QueueFamilyProperties, family_count, allocator=context.temp_allocator)
		vk.GetPhysicalDeviceQueueFamilyProperties(current_device, &family_count, raw_data(family_props)) 
		current_graphics_family: u32 
		found_graphics_family := false
		for family_prop, n in family_props { 
			if .GRAPHICS not_in family_prop.queueFlags { 
				continue 
			} 

			supported: b32 
			vk.GetPhysicalDeviceSurfaceSupportKHR(current_device, u32(n), s.surface, &supported) 
			if !supported { 
				continue 
			}

			found_graphics_family = true
			current_graphics_family = u32(n)
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

	d.physical = physical_device
	d.properties = device_properties
	d.graphics_queue_family = graphics_queue_family

	log.infof(
		"Selected %vdevice '%v', Vulkan API version %v.%v.%v", 
		device_type_names[device_properties.deviceType],
		bytes_to_string(device_properties.deviceName[:]),
		vk.VERSION_MAJOR(device_properties.apiVersion),
		vk.VERSION_MINOR(device_properties.apiVersion),
		vk.VERSION_PATCH(device_properties.apiVersion),
	)
}

@(private="file")
check_device_features :: proc(
	device: vk.PhysicalDevice,
	name: string,
	api_version: u32,
) -> bool {
	vk11 := vk.PhysicalDeviceVulkan11Features {
		sType = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, 
	}

	vk12 := vk.PhysicalDeviceVulkan12Features {
		sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, 
		pNext = &vk11,
	}

	vk13 := vk.PhysicalDeviceVulkan13Features {
		sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, 
		pNext = &vk12,
	}
	
	dyn_render := vk.PhysicalDeviceDynamicRenderingFeaturesKHR {
		sType = .PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES_KHR,
		pNext = &vk12,
	}

	sync2 := vk.PhysicalDeviceSynchronization2FeaturesKHR {
		sType = .PHYSICAL_DEVICE_SYNCHRONIZATION_2_FEATURES_KHR,
		pNext = &dyn_render,
	}

	features := vk.PhysicalDeviceFeatures2 {
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		pNext = &vk13 if api_version >= vk.API_VERSION_1_3 else &sync2,
	}
	vk.GetPhysicalDeviceFeatures2(device, &features)

	ok := true
	check :: proc(supported: b32, feature: string, device: string, ok: ^bool) {
		if !supported {
			log.debugf("[%s] Device rejected: missing feature '%s'", device, feature)
			ok^ = false
		}
	}

	check(features.features.imageCubeArray, "imageCubeArray", name, &ok)
	check(features.features.samplerAnisotropy, "samplerAnisotropy", name, &ok)
	check(features.features.multiDrawIndirect, "multiDrawIndirect", name, &ok)
	check(vk11.shaderDrawParameters, "shaderDrawParameters", name, &ok)
	check(vk12.drawIndirectCount, "drawIndirectCount", name, &ok)
	check(vk12.scalarBlockLayout, "scalarBlockLayout", name, &ok)
	check(vk12.bufferDeviceAddress, "bufferDeviceAddress", name, &ok)
	check(vk12.descriptorIndexing, "descriptorIndexing", name, &ok)
	check(vk12.runtimeDescriptorArray, "runtimeDescriptorArray", name, &ok)
	check(vk12.descriptorBindingPartiallyBound, "descriptorBindingPartiallyBound", name, &ok)
	check(vk12.descriptorBindingSampledImageUpdateAfterBind, "descriptorBindingSampledImageUpdateAfterBind", name, &ok)
	check(vk12.shaderSampledImageArrayNonUniformIndexing, "shaderSampledImageArrayNonUniformIndexing", name, &ok)

	if api_version >= vk.API_VERSION_1_3 {
		check(vk13.dynamicRendering, "dynamicRendering", name, &ok)
		check(vk13.synchronization2, "synchronization2", name, &ok)
	} else {
		check(dyn_render.dynamicRendering, "dynamicRendering", name, &ok)
		check(sync2.synchronization2, "synchronization2", name, &ok)
	}

	return ok
}

@(private="file")
create_device_and_queues :: proc(d: ^Device) {
	queue_create_infos := []vk.DeviceQueueCreateInfo {
		{
			sType = .DEVICE_QUEUE_CREATE_INFO,
			queueFamilyIndex = d.graphics_queue_family,
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
	if d.properties.apiVersion >= vk.API_VERSION_1_3 {
		device_features_extra = rawptr(&device_features_vk13)
	} else {
		device_features_extra = rawptr(&sync2_features)
	}

	device_exts := [dynamic; 8]cstring{}
	append(&device_exts, vk.KHR_SWAPCHAIN_EXTENSION_NAME)
	if d.properties.apiVersion < vk.API_VERSION_1_3 {
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

	must(vk.CreateDevice(d.physical, &device_info, nil, &d.logical))
	vk.load_proc_addresses_device(d.logical)
	vk.GetDeviceQueue(d.logical, d.graphics_queue_family, 0, &d.graphics_queue)
}

