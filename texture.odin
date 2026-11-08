package main
import vk "vendor:vulkan"
import "core:container/handle_map"

Texture_Handle :: distinct handle_map.Handle64

Texture_Sampler :: enum {
	Linear_Repeat,
	Linear_Mirror,
	Linear_Clamp,
	Nearest_Repeat,
	Nearest_Clamp,
	Nearest_Mirror,
}

Texture_Filter :: enum {
	Linear,
	Nearest,
}

Texture_Mipmap_Mode :: enum {
	Linear,
	Nearest,
}

Texture_Sampler_Options :: struct {
    min_filter:     Texture_Filter,
    mipmap_mode:    Texture_Mipmap_Mode,
    max_anisotropy: Maybe(f32),
    min_lod:        f32,
    max_lod:        Maybe(f32),
    lod_bias:       f32,
}

Texture_Fallback :: enum {
	Color_Error,
	Color_Default,
	Normal,
	Displacement,
	Aorm,
}

Texture_Access_Error :: enum {
	None = 0,
	Invalid_Handle,
	Subresource_Range_Out_Of_Bounds,
	Empty_Subresource_Range,
	Invalid_View_Configuration,
}

Texture_Init_Error :: enum {
	None = 0,
	Allocation_Failed,
	Upload_Failed,
	No_Bindless_Slots_Left,
}

Texture_Error :: union #shared_nil {
	Texture_Access_Error,
	Texture_Init_Error,
	vk.Result,
}

@(require_results)
default_texture_sampler_options :: proc() -> Texture_Sampler_Options {
	return {
		min_filter = .Linear,
		mipmap_mode = .Linear,
	}
}

@(require_results)
get_texture_sampler_index :: proc(sampler: Texture_Sampler) -> u32 {
	return u32(sampler)
}

texture_filter_to_vk :: proc(filter: Texture_Filter) -> vk.Filter {
	switch filter {
	case .Linear: return .LINEAR
	case .Nearest: return .NEAREST
	}
	return .NEAREST
}

texture_mipmap_mode_to_vk :: proc(mode: Texture_Mipmap_Mode) -> vk.SamplerMipmapMode {
	switch mode {
	case .Linear: return .LINEAR
	case .Nearest: return .NEAREST
	}
	return .NEAREST
}
