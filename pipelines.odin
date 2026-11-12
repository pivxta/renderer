package main
import vk "vendor:vulkan"

Cull_Mode :: enum {
	None,
	Back,
	Front,
}

Blend_Mode :: enum {
	Opaque,
	Alpha,
	Premultiplied,
	Additive,
	Multiply,
}

Raster_State :: struct {
	cull_mode: Cull_Mode,
	blend_mode: Blend_Mode,
	depth_test: bool,
	depth_write: bool,
	depth_compare: vk.CompareOp,
	depth_bias: bool,
}
