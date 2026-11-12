package main
import "core:container/handle_map"

Material_Handle :: distinct handle_map.Handle64

Material_Properties :: struct {
	blend_mode:   Blend_Mode,
	alpha_test:   bool,
	double_sided: bool,
}

Material_Error :: enum {
	None,
	Invalid_Handle,
	Out_Of_Gpu_Memory,
	Type_Not_Registered,
	Type_Does_Not_Match,
}

Unlit_Material :: struct {
	color_factor: Maybe([3]f32),
	color_texture: Maybe(Texture_Handle),
	sampler: Texture_Sampler,
}

Unlit_Material_Data :: struct {
	color_factor: [3]f32,
	color_texture: Texture_Index,
	sampler: Texture_Sampler,
	flags: Unlit_Material_Flags,
}

Unlit_Material_Flag :: enum {
	Has_Base_Color_Texture,
}

Unlit_Material_Flags :: bit_set[Unlit_Material_Flag; u32]

resolve_unlit :: proc(textures: ^Textures, params: Unlit_Material) -> Unlit_Material_Data {
	flags := Unlit_Material_Flags{}

	color_texture, color_ok := params.color_texture.?
	color_index: Texture_Index
	if color_ok {
		color_index = textures_get_index(textures, color_texture, .Color_Error)
		flags += {.Has_Base_Color_Texture}
	}

	return {
		color_factor = params.color_factor.? or_else {1.0, 1.0, 1.0},
		color_texture = color_index,
		sampler = params.sampler,
		flags = flags,
	}
}

Lambert_Material :: struct {
	base_color_factor: Maybe([4]f32),
	base_color_texture: Maybe(Texture_Handle),
	sampler: Texture_Sampler,
}

Lambert_Material_Data :: struct {
	base_color_factor: [4]f32,
	base_color_texture: Texture_Index,
	sampler: Texture_Sampler,
	flags: Lambert_Material_Flags,
}

Lambert_Material_Flag :: enum {
	Has_Base_Color_Texture,
}

Lambert_Material_Flags :: bit_set[Lambert_Material_Flag; u32]

resolve_lambert :: proc(textures: ^Textures, params: Lambert_Material) -> Lambert_Material_Data {
	flags := Lambert_Material_Flags{}

	base_color_texture, base_color_ok := params.base_color_texture.?
	base_color_index: Texture_Index
	if base_color_ok {
		base_color_index = textures_get_index(textures, base_color_texture, .Color_Error)
		flags += {.Has_Base_Color_Texture}
	}

	return {
		base_color_factor = params.base_color_factor.? or_else {1.0, 1.0, 1.0, 1.0},
		base_color_texture = base_color_index,
		sampler = params.sampler,
		flags = flags,
	}
}

