package main
import "core:mem"
import "core:slice"
import "core:strings"
import "base:runtime"
import stbi "vendor:stb/image"
import vk "vendor:vulkan"

Image :: struct {
	width: int,
	height: int,
	bytes: []byte,
	format: Image_Format,
	allocator: runtime.Allocator,
}

Image_Format :: enum {
	R_U8,
	Rg_U8,
	Rgba_U8,
	R_F16,
	Rg_F16,
	Rgba_F16,
}

Image_Load_Error :: enum {
	None = 0,
	Invalid_Or_Nonexistent_File,
}

Image_Error :: union #shared_nil {
	Image_Load_Error,
	runtime.Allocator_Error,
}

image_make :: proc(
	width, height: int, 
	format: Image_Format, 
	allocator := context.allocator,
) -> (image: Image, err: runtime.Allocator_Error) {
	image.format = format
	image.width = width
	image.height = height
	image.allocator = allocator
	image.bytes = make([]byte, width * height * image_format_texel_size(format), allocator) or_return
	return
}

image_load_from_file :: proc(
	filename: string, 
	allocator := context.allocator,
) -> (image: Image, err: Image_Error) {
	cfilename := strings.clone_to_cstring(filename)
	defer delete(cfilename) 

	width, height, components: i32
	if stbi.info(cfilename, &width, &height, &components) == 0 {
		return {}, Image_Load_Error.Invalid_Or_Nonexistent_File
	}

	if components == 3 {
		components = 4
	}

	is_hdr := stbi.is_hdr(cfilename) != 0
	format: Image_Format
	if is_hdr {
		switch components {
		case 1: format = .R_F16
		case 2: format = .Rg_F16
		case 4: format = .Rgba_F16
		case: unreachable()
		}
	} else {
		switch components {
		case 1: format = .R_U8
		case 2: format = .Rg_U8
		case 4: format = .Rgba_U8
		case: unreachable()
		}
	}

	image = image_make(int(width), int(height), format, allocator) or_return
	defer if err != nil {
		image_destroy(&image)
	}

	if is_hdr {
		loaded_values := stbi.loadf(cfilename, &width, &height, nil, components)
		if loaded_values == nil {
			err = Image_Load_Error.Invalid_Or_Nonexistent_File
			return
		}

		values := slice.reinterpret([]f16, image.bytes)
		for i in 0..<len(values) {
			values[i] = f16(clamp(loaded_values[i], -65504, 65504))
		}

		stbi.image_free(loaded_values)
	} else {
		loaded_values := stbi.load(cfilename, &width, &height, nil, components)
		if loaded_values == nil {
			err = Image_Load_Error.Invalid_Or_Nonexistent_File
			return
		}

		mem.copy(raw_data(image.bytes), loaded_values, len(image.bytes))
		stbi.image_free(loaded_values)
	}
	
	return image, nil
}

image_destroy :: proc(image: ^Image) {
	if image == nil {
		return
	}

	delete(image.bytes, image.allocator)
	image^ = {}
}

image_pixels :: proc($T: typeid, image: ^Image) -> []T {
	assert(image != nil)
	assert(size_of(T) == image_format_texel_size(image.format))
	return slice.reinterpret([]T, image.bytes)
}

image_is_valid :: proc(image: Image) -> bool {
	return image.width > 0 &&
	       image.height > 0 &&
	       len(image.bytes) == image.width * image.height * image_format_texel_size(image.format)
}

image_format_texel_size :: proc(fmt: Image_Format) -> int {
	switch fmt {
	case .R_U8: return 1
	case .Rg_U8: return 2
	case .Rgba_U8: return 4
	case .R_F16: return 2
	case .Rg_F16: return 4
	case .Rgba_F16: return 8 
	}
	unreachable()
}

image_format_matches_vk :: proc(fmt: Image_Format, vkfmt: vk.Format) -> bool {
	#partial switch vkfmt {
	case .R8_UNORM, .R8_SRGB, .R8_UINT:
		return fmt == .R_U8
	case .R8G8_UNORM, .R8G8_SRGB, .R8G8_UINT:
		return fmt == .Rg_U8
	case .R8G8B8A8_UNORM, .R8G8B8A8_SRGB, .R8G8B8A8_UINT:
		return fmt == .Rgba_U8
	case .R16_SFLOAT:
		return fmt == .R_F16
	case .R16G16_SFLOAT:
		return fmt == .Rg_F16
	case .R16G16B16A16_SFLOAT:
		return fmt == .Rgba_F16
	case:
		return false
	}
}

image_format_to_vk :: proc(fmt: Image_Format, srgb: bool) -> vk.Format {
	if srgb {
		switch fmt {
		case .R_U8: return .R8_UNORM
		case .Rg_U8: return .R8G8_UNORM 
		case .Rgba_U8: return .R8G8B8A8_SRGB
		case .R_F16: return .R16_SFLOAT
		case .Rg_F16: return .R16G16_SFLOAT
		case .Rgba_F16: return .R16G16B16A16_SFLOAT
		}
	} else {
		switch fmt {
		case .R_U8: return .R8_UNORM
		case .Rg_U8: return .R8G8_UNORM 
		case .Rgba_U8: return .R8G8B8A8_UNORM
		case .R_F16: return .R16_SFLOAT
		case .Rg_F16: return .R16G16_SFLOAT
		case .Rgba_F16: return .R16G16B16A16_SFLOAT
		}
	}
	unreachable()
}
