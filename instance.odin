package main 
import "base:runtime"
import "core:log"
import "vendor:glfw"
import vk "vendor:vulkan"

ENABLE_VALIDATION :: #config(ENABLE_VALIDATION, ODIN_DEBUG)
ENABLE_SYNC_VALIDATION :: #config(ENABLE_SYNC_VALIDATION, ODIN_DEBUG)
VALIDATION_LAYER_NAME :: "VK_LAYER_KHRONOS_validation"

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
instance_init :: proc (instance: ^Instance) -> (err: Instance_Error) {
	assert(instance != nil)

	instance^ = {}
	defer if err != nil {
		instance_destroy(instance)
	}

	vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))

	app_info := vk.ApplicationInfo {
		sType = .APPLICATION_INFO,
		applicationVersion = vk.MAKE_VERSION(1, 0, 0),
		engineVersion = vk.MAKE_VERSION(1, 0, 0),
		apiVersion = vk.API_VERSION_1_3,
	}

	// Instance extensions
	extensions := make([dynamic]cstring, 0, context.temp_allocator)

	// Check all required extensions
	extension_props := enumerate_extensions(nil, context.temp_allocator) or_return

	required_extensions := glfw.GetRequiredInstanceExtensions()
	for required_extension in required_extensions {
		if check_extension(extension_props, required_extension) {
			log.debugf("Enabled Vulkan extension '%v'", required_extension)
			append(&extensions, required_extension)
		} else {
			log.errorf("Required extension '%v' not available", required_extension)
			return Instance_Init_Error.Required_Extension_Not_Available
		}
	}
	
	// Probe for the debug utils extension
	debug_utils_enabled := false
	if check_extension(extension_props, vk.EXT_DEBUG_UTILS_EXTENSION_NAME) {
		log.debugf("Enabled Vulkan extension '%v'", vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
		append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
		debug_utils_enabled = true
	}
	
	// Instance layers
	layers := make([dynamic]cstring, 0, allocator=context.temp_allocator)
	layer_settings_enabled := false

	when ENABLE_VALIDATION {
		// Probe for validation layer
		layer_prop_count: u32 
		vk.EnumerateInstanceLayerProperties(&layer_prop_count, nil) or_return
		layer_props := make([]vk.LayerProperties, layer_prop_count, allocator=context.temp_allocator)
		vk.EnumerateInstanceLayerProperties(&layer_prop_count, raw_data(layer_props)) or_return

		validation_enabled := false
		for &layer_prop in layer_props {
			if bytes_to_string(layer_prop.layerName[:]) == VALIDATION_LAYER_NAME {
				log.debug("Vulkan validation layers enabled")
				append(&layers, VALIDATION_LAYER_NAME)
				validation_enabled = true
			}
		}
		
		if validation_enabled {
			// Probe for layer settings extension
			layer_extension_props := enumerate_extensions(VALIDATION_LAYER_NAME, 
			                                              context.temp_allocator) or_return

			if check_extension(layer_extension_props, vk.EXT_LAYER_SETTINGS_EXTENSION_NAME) {
				log.debugf("Enabled Vulkan extension '%v'", vk.EXT_LAYER_SETTINGS_EXTENSION_NAME)
				append(&extensions, vk.EXT_LAYER_SETTINGS_EXTENSION_NAME)
				layer_settings_enabled = true
			}
		} else {
			log.warnf("Validation layer requested but %v is not installed", VALIDATION_LAYER_NAME)
		}
	}
	
	// Instance creation
	instance_info := vk.InstanceCreateInfo {
		sType = .INSTANCE_CREATE_INFO,
		pApplicationInfo = &app_info,
		enabledExtensionCount = u32(len(extensions)),
		ppEnabledExtensionNames = raw_data(extensions),
		enabledLayerCount = u32(len(layers)),
		ppEnabledLayerNames = raw_data(layers),
	}

	layer_settings_info: vk.LayerSettingsCreateInfoEXT
	validate_sync := b32(ENABLE_SYNC_VALIDATION)
	validation_layer_settings := [?]vk.LayerSettingEXT {
		{
			pLayerName = VALIDATION_LAYER_NAME,
			pSettingName = "validate_sync",
			type = .BOOL32,
			valueCount = 1,
			pValues = &validate_sync,
		},
	}
	if layer_settings_enabled {
		layer_settings_info = {
			sType = .LAYER_SETTINGS_CREATE_INFO_EXT,
			pNext = instance_info.pNext,
			settingCount = u32(len(validation_layer_settings)),
			pSettings = raw_data(validation_layer_settings[:]),
		}

		instance_info.pNext = &layer_settings_info
	}

	debug_messenger_info: vk.DebugUtilsMessengerCreateInfoEXT
	if debug_utils_enabled {
		severity: vk.DebugUtilsMessageSeverityFlagsEXT
		if context.logger.lowest_level <= .Error {
			severity |= {.ERROR}
		}
		if context.logger.lowest_level <= .Warning {
			severity |= {.WARNING}
		}

		messenger_context := new_clone(runtime.default_context())
		messenger_context.logger = log.create_console_logger(
			lowest=context.logger.lowest_level,
			opt=context.logger.options & {.Level, .Date, .Time, .Terminal_Color},
			ident="Vulkan",
		)

		debug_messenger_info = {
			sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
			pNext = instance_info.pNext,
			messageSeverity = severity,
			messageType = {.GENERAL, .VALIDATION, .PERFORMANCE},
			pfnUserCallback = messenger_callback,
			pUserData = messenger_context,
		}

		instance.messenger_context = messenger_context
		instance_info.pNext = &debug_messenger_info
	}

	vk.CreateInstance(&instance_info, nil, &instance.handle) or_return
	vk.load_proc_addresses_instance(instance.handle)

	if debug_utils_enabled {
		vk.CreateDebugUtilsMessengerEXT(
			instance.handle, 
			&debug_messenger_info, nil, 
			&instance.debug_messenger,
		) or_return
	}

	return nil
}

@(private="file")
enumerate_extensions :: proc(
	layer: cstring, 
	allocator: runtime.Allocator,
) -> (props: []vk.ExtensionProperties, result: vk.Result) {
	count: u32 
	vk.EnumerateInstanceExtensionProperties(layer, &count, nil) or_return

	props = make([]vk.ExtensionProperties, count, allocator)
	defer if result != .SUCCESS {
		delete(props, allocator)
	}
	vk.EnumerateInstanceExtensionProperties(layer, &count, raw_data(props)) or_return

	return props, .SUCCESS
}

@(private="file")
check_extension :: proc(props: []vk.ExtensionProperties, extension: cstring) -> bool {
	for &p in props {
		current_extension_name := cstring(raw_data(p.extensionName[:]))
		if current_extension_name == extension {
			return true
		}
	}
	return false
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

