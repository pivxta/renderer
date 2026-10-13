package main
import "core:strings"
import "core:log"
import vk "vendor:vulkan"

must :: proc(result: vk.Result, location := #caller_location) {
	if result != .SUCCESS {
		log.panicf("Fatal Vulkan error: %v", result, location=location)
	}
}

bytes_to_string :: proc(bytes: []byte) -> string {
	return strings.truncate_to_byte(string(bytes), 0)
}


