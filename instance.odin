package main
import "base:runtime"
import "core:log"
import "vendor:glfw"
import vk "vendor:vulkan"

Instance :: struct {
	handle: vk.Instance,
	debug_messenger: vk.DebugUtilsMessengerEXT,
	messenger_context: ^runtime.Context,
}

Instance_Init_Error :: enum {
	None = 0,
	Required_Extension_Not_Available,
}

Instance_Error :: union #shared_nil {
	Instance_Init_Error,
	vk.Result,
}

@(require_results)
instance_init :: proc (i: ^Instance) -> (err: Instance_Error) {
	assert(i != nil)

	defer if err != nil {
		instance_destroy(i)
	}

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
	vk.EnumerateInstanceExtensionProperties(nil, &instance_ext_prop_count, nil) or_return
	instance_ext_props := make(
		[]vk.ExtensionProperties, 
		instance_ext_prop_count, 
		allocator=context.temp_allocator,
	)
	vk.EnumerateInstanceExtensionProperties(
		nil, &instance_ext_prop_count, 
		raw_data(instance_ext_props),
	) or_return

	outer: for req_ext in req_instance_exts {
		for &instance_ext_prop in instance_ext_props {
			if req_ext == cstring(raw_data(instance_ext_prop.extensionName[:])) {
				append(&instance_exts, req_ext)
				continue outer
			}
		}
		log.errorf("Required extension '%v' not available", req_ext)
		return Instance_Init_Error.Required_Extension_Not_Available
	}

	// Instance layers
	layers := make([dynamic]cstring, 0, allocator=context.temp_allocator)

	layer_prop_count: u32 
	vk.EnumerateInstanceLayerProperties(&layer_prop_count, nil) or_return
	layer_props := make([]vk.LayerProperties, layer_prop_count, allocator=context.temp_allocator)
	vk.EnumerateInstanceLayerProperties(&layer_prop_count, raw_data(layer_props)) or_return

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

	i.messenger_context = new_clone(runtime.default_context())
	i.messenger_context.logger = log.create_console_logger(
		lowest=context.logger.lowest_level,
		opt=context.logger.options & {.Level, .Date, .Time, .Terminal_Color},
		ident="Vulkan",
	)

	debug_messenger_info := vk.DebugUtilsMessengerCreateInfoEXT {
		sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
		messageSeverity = severity,
		messageType = {.GENERAL, .VALIDATION, .PERFORMANCE},
		pfnUserCallback = messenger_callback,
		pUserData = i.messenger_context,
	}
	instance_info.pNext = &debug_messenger_info

	vk.CreateInstance(&instance_info, nil, &i.handle) or_return
	vk.load_proc_addresses_instance(i.handle)
	vk.CreateDebugUtilsMessengerEXT(
		i.handle, 
		&debug_messenger_info, nil, 
		&i.debug_messenger,
	) or_return

	return nil
}

instance_destroy :: proc(i: ^Instance) {
	if i == nil {
		return
	}

	if i.handle != nil && i.debug_messenger != 0 {
		vk.DestroyDebugUtilsMessengerEXT(i.handle, i.debug_messenger, nil)
	}
	if i.handle != nil {
		vk.DestroyInstance(i.handle, nil)
	}
	if i.messenger_context != nil {
		log.destroy_console_logger(i.messenger_context.logger)
		free(i.messenger_context)
	}
	i^ = {}
}

@(private="file")
messenger_callback :: proc "system" (
	severity: vk.DebugUtilsMessageSeverityFlagsEXT,
	types: vk.DebugUtilsMessageTypeFlagsEXT,
	callback_data: ^vk.DebugUtilsMessengerCallbackDataEXT,
	user_data: rawptr,
) -> b32 {
	if user_data == nil {
		return false
	}

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

