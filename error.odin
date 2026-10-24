package main
import "core:log"
import vk "vendor:vulkan"

must :: proc(result: vk.Result, location := #caller_location) {
	if result != .SUCCESS {
		log.panicf("Fatal Vulkan error: %v", result, location=location)
	}
}
