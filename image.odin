package main
import "core:mem"
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
	R_F32,
	Rg_F32,
	Rgba_F32,
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
		return
	}

	if components == 3 {
		components = 4
	}

	loaded_bytes: rawptr 
	is_float := stbi.is_hdr(cfilename) != 0
	if is_float {
		loaded_bytes = stbi.loadf(cfilename, &width, &height, nil, components)
	} else {
		loaded_bytes = stbi.load(cfilename, &width, &height, nil, components)
	}
	if loaded_bytes == nil {
		return
	}
	defer stbi.image_free(loaded_bytes)
	
	format: Image_Format
	if is_float {
		switch components {
		case 1: format = .R_F32
		case 2: format = .Rg_F32
		case 4: format = .Rgba_F32
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
	mem.copy(raw_data(image.bytes), loaded_bytes, len(image.bytes))
	return
}

image_destroy :: proc(image: ^Image) {
	if image == nil {
		return
	}

	delete(image.bytes, image.allocator)
	image^ = {}
}

image_pixels :: proc($T: typeid, image: ^Image) -> []T {
	assert(size_of(T) == image_format_texel_size(image))
	return slice.reinterpret([]T, image.bytes)
}

image_format_texel_size :: proc(fmt: Image_Format) -> int {
	switch fmt {
	case .R_U8: return 1
	case .Rg_U8: return 2
	case .Rgba_U8: return 4
	case .R_F32: return 4
	case .Rg_F32: return 8
	case .Rgba_F32: return 16
	}
	unreachable()
}

image_format_to_vk :: proc(fmt: Image_Format, srgb: bool) -> vk.Format {
	if srgb {
		switch fmt {
		case .R_U8: return .R8_SRGB
		case .Rg_U8: return .R8G8_SRGB 
		case .Rgba_U8: return .R8G8B8A8_SRGB
		case .R_F32: return .R32_SFLOAT
		case .Rg_F32: return .R32G32_SFLOAT
		case .Rgba_F32: return .R32G32B32A32_SFLOAT
		}
	} else {
		switch fmt {
		case .R_U8: return .R8_UNORM
		case .Rg_U8: return .R8G8_UNORM 
		case .Rgba_U8: return .R8G8B8A8_UNORM
		case .R_F32: return .R32_SFLOAT
		case .Rg_F32: return .R32G32_SFLOAT
		case .Rgba_F32: return .R32G32B32A32_SFLOAT
		}
	}
	unreachable()
}
