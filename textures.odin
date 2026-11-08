package main
import vk "vendor:vulkan"
import "core:slice"
import "core:container/handle_map"

Textures :: struct {
	textures:             Bindless_Textures,
	samplers:             Bindless_Samplers(Texture_Sampler),
	sampler_options:      Texture_Sampler_Options,
	reconfigure_samplers: bool,

	fallbacks:            [Texture_Fallback]Bindless_Handle,
	updated:              [dynamic]Texture_Handle,
	handle_map:           handle_map.Dynamic_Handle_Map(Texture_Slot, Texture_Handle),
}

@(private="file")
Texture_Slot :: struct {
	handle:          Texture_Handle,
	texture_handle:  Maybe(Bindless_Handle),
	fallback_handle: Bindless_Handle,
}

@(private="file")
TEXTURE_SAMPLER_DESCS := [Texture_Sampler]Sampler_Desc {
	.Linear_Repeat = {address_mode = .REPEAT, mag_filter = .LINEAR},
	.Linear_Mirror = {address_mode = .MIRRORED_REPEAT, mag_filter = .LINEAR},
	.Linear_Clamp = {address_mode = .CLAMP_TO_EDGE, mag_filter = .LINEAR},
	.Nearest_Repeat = {address_mode = .REPEAT, mag_filter = .NEAREST},
	.Nearest_Mirror = {address_mode = .MIRRORED_REPEAT, mag_filter = .NEAREST},
	.Nearest_Clamp = {address_mode = .CLAMP_TO_EDGE, mag_filter = .NEAREST},
}

textures_init :: proc(
	textures: ^Textures,
	device: Device,
	upload_queue: ^Upload_Queue,
	frame_ring: Frame_Ring,
	capacity: int,
	sampler_options: Maybe(Texture_Sampler_Options) = nil,
	allocator := context.allocator,
) -> (err: Texture_Error) {
	assert(textures != nil)
	assert(capacity >= len(Texture_Fallback) + 1)

	textures^ = {}
	defer if err != nil {
		textures_destroy(textures, device)
	}
	
	sampler_options := sampler_options.? or_else default_texture_sampler_options()
	sampler_globals := sampler_options_to_globals(sampler_options)
	bindless_init(&textures.textures, device, capacity, allocator) or_return
	bindless_samplers_init(
		&textures.samplers, device, 
		TEXTURE_SAMPLER_DESCS, sampler_globals,
	) or_return

	handle_map.dynamic_init(&textures.handle_map, allocator)
	textures.sampler_options = sampler_options
	textures.updated = make([dynamic]Texture_Handle, allocator)
	textures.fallbacks = create_fallbacks(
		&textures.textures, device, 
		upload_queue, frame_ring,
	) or_return

	return nil
}

@(private="file", require_results)
create_fallbacks :: proc(
	textures: ^Bindless_Textures, 
	device: Device,
	upload_queue: ^Upload_Queue,
	frame_ring: Frame_Ring,
) -> (fallbacks: [Texture_Fallback]Bindless_Handle, err: Texture_Error) {
	for &fallback, fallback_type in fallbacks {
		fallback = create_fallback(textures, device, upload_queue, frame_ring, fallback_type) or_return
	}

	return fallbacks, nil
}

@(private="file", require_results)
create_fallback :: proc(
	textures: ^Bindless_Textures, 
	device: Device,
	upload_queue: ^Upload_Queue, 
	frame_ring: Frame_Ring,
	fallback: Texture_Fallback,
) -> (handle: Bindless_Handle, err: Texture_Error) {
	image := create_fallback_image(fallback, context.temp_allocator)
	texture := create_texture(device, image, false) or_return
	texture_handle, ok := bindless_add(textures, device, texture)
	if !ok {
		texture_destroy(&texture, device)
		return {}, .No_Bindless_Slots_Left
	}

	if err = upload_to_texture(upload_queue, frame_ring, texture, image); err != nil {
		bindless_remove(textures, frame_ring, texture_handle)
		return {}, err
	}

	return texture_handle, nil
}

@(private="file", require_results)
create_fallback_image :: proc(
	fallback: Texture_Fallback, 
	allocator := context.allocator,
) -> Image {
	image, err := image_make(1, 1, .Rgba_F16, allocator)
	assert(err == nil)

	pixels := slice.reinterpret([][4]f16, image.bytes)
	fill_color := [4]f16 {}
	switch fallback {
	case .Color_Error:
		fill_color = {1.0, 0.0, 1.0, 1.0}
	case .Color_Default:
		fill_color = {0.8, 0.8, 0.8, 1.0}
	case .Normal:
		fill_color = {0.5, 0.5, 1.0, 1.0}
	case .Displacement:
		fill_color = {0.0, 0.0, 0.0, 0.0}
	case .Aorm:
		fill_color = {1.0, 0.5, 0.0, 0.0}
	}
	for i in 0..<image.width {
		for j in 0..<image.height {
			pixels[j * image.width + i] = fill_color
		}
	}

	return image
}

@(private="file", require_results)
sampler_options_to_globals :: proc(options: Texture_Sampler_Options) -> Sampler_Globals {
	return {
		min_filter = texture_filter_to_vk(options.min_filter),
		mipmap_mode = texture_mipmap_mode_to_vk(options.mipmap_mode),
		max_anisotropy = options.max_anisotropy,
		min_lod = options.min_lod,
		max_lod = options.max_lod,
		lod_bias = options.lod_bias,
	}
}

textures_destroy :: proc(textures: ^Textures, device: Device) {
	if textures == nil {
		return
	}

	handle_map.dynamic_destroy(&textures.handle_map)
	if textures.updated != nil {
		delete(textures.updated)
	}
	bindless_samplers_destroy(&textures.samplers, device)
	bindless_destroy(&textures.textures, device)
	textures^ = {}
}

@(require_results)
textures_reserve :: proc(
	textures: ^Textures, 
	fallback := Texture_Fallback.Color_Default,
) -> Texture_Handle {
	assert(textures != nil)
	return handle_map.add(&textures.handle_map, {
		texture_handle = nil,
		fallback_handle = textures.fallbacks[fallback],
	})
}

@(require_results)
textures_add :: proc(
	textures: ^Textures, 
	device: Device,
	upload_queue: ^Upload_Queue,
	frame_ring: Frame_Ring,
	image: Image,
	srgb := true,
	fallback := Texture_Fallback.Color_Error,
) -> (handle: Texture_Handle, err: Texture_Error) {
	assert(textures != nil)

	handle = textures_reserve(textures, fallback)
	textures_replace(textures, device, upload_queue, frame_ring, handle, image, srgb) or_return
	return handle, nil
}

textures_replace :: proc(
	textures: ^Textures, 
	device: Device,
	upload_queue: ^Upload_Queue,
	frame_ring: Frame_Ring,
	handle: Texture_Handle,
	image: Image,
	srgb := true,
) -> Texture_Error {
	assert(textures != nil)

	slot, slot_ok := handle_map.get(&textures.handle_map, handle)
	if !slot_ok {
		return .Invalid_Handle
	}

	new_texture := create_texture(device, image, srgb) or_return
	new_texture_handle, bindless_ok := bindless_add(&textures.textures, device, new_texture)
	if !bindless_ok {
		texture_destroy(&new_texture, device)
		return .No_Bindless_Slots_Left
	}

	if err := upload_to_texture(upload_queue, frame_ring, new_texture, image); err != nil {
		bindless_remove(&textures.textures, frame_ring, new_texture_handle)
		return err
	}

	if old_texture_handle, ok := slot.texture_handle.?; ok {
		bindless_remove(&textures.textures, frame_ring, old_texture_handle)
		append(&textures.updated, handle)
	}
	
	slot.texture_handle = new_texture_handle
	return nil
}

@(private="file", require_results)
create_texture :: proc(
	device: Device,
	image: Image,
	srgb := true,
) -> (texture: Texture, err: Texture_Error) {
	texture_init(
		&texture, device,
		type = .D2,
		usage = {.TRANSFER_DST, .TRANSFER_SRC, .SAMPLED},
		format = image_format_to_vk(image.format, srgb),
		extent = {u32(image.width), u32(image.height), 1},
	) or_return

	return texture, nil
}

@(private="file", require_results)
upload_to_texture :: proc(
	upload_queue: ^Upload_Queue, 
	frame_ring: Frame_Ring, 
	texture: Texture,
	image: Image,
) -> Texture_Error {
	ok := upload_texture(
		upload_queue, 
		frame_ring, 
		texture, image,
		{ 
			stages = {.VERTEX_SHADER, .FRAGMENT_SHADER},
			access = {.SHADER_SAMPLED_READ},
			layout = .SHADER_READ_ONLY_OPTIMAL,
		},
	)
	if !ok {
		return .Upload_Failed
	}
	return nil
}

textures_remove :: proc(textures: ^Textures, frame_ring: Frame_Ring, handle: Texture_Handle) {
	assert(textures != nil)

	if slot, slot_ok := handle_map.get(&textures.handle_map, handle); slot_ok {
		if texture_handle, texture_handle_ok := slot.texture_handle.?; texture_handle_ok {
			bindless_remove(&textures.textures, frame_ring, texture_handle)
			append(&textures.updated, handle)
		}
		handle_map.remove(&textures.handle_map, handle)
	}
}

@(require_results)
textures_get_index :: proc(
	textures: ^Textures, 
	handle: Texture_Handle, 
	fallback := Texture_Fallback.Color_Error,
) -> (u32, bool) {
	assert(textures != nil)
	
	if slot, slot_ok := handle_map.get(&textures.handle_map, handle); slot_ok {
		if texture_handle, texture_handle_ok := slot.texture_handle.?; texture_handle_ok {
			return texture_handle.idx, true
		} else {
			return slot.fallback_handle.idx, true
		}
	}

	return textures.fallbacks[fallback].idx, false
}

@(require_results)
textures_get_texture_set :: proc(textures: Textures) -> vk.DescriptorSet {
	return textures.textures.descriptor_set
}

@(require_results)
textures_get_sampler_set :: proc(textures: Textures) -> vk.DescriptorSet {
	return textures.samplers.descriptor_set
}

@(require_results)
textures_get_texture_set_layout :: proc(textures: Textures) -> vk.DescriptorSetLayout {
	return textures.textures.descriptor_set_layout
}

@(require_results)
textures_get_sampler_set_layout :: proc(textures: Textures) -> vk.DescriptorSetLayout {
	return textures.samplers.descriptor_set_layout
}

textures_destroy_pending :: proc(textures: ^Textures, device: Device, finished_value: u64) {
	assert(textures != nil)
	bindless_destroy_pending(&textures.textures, device, finished_value)
}

textures_set_sampler_options :: proc(textures: ^Textures, options: Texture_Sampler_Options) {
	assert(textures != nil)
	textures.sampler_options = options
	textures.reconfigure_samplers = true
}

textures_reconfigure_dirty_samplers :: proc(textures: ^Textures, device: Device) -> vk.Result {
	assert(textures != nil)
	if textures.reconfigure_samplers {
		sampler_globals := sampler_options_to_globals(textures.sampler_options)
		bindless_samplers_configure(&textures.samplers, device, sampler_globals) or_return
		textures.reconfigure_samplers = false
	}
	return .SUCCESS
}
