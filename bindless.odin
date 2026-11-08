package main

import "base:intrinsics"
import "core:container/handle_map"
@(require) import "core:container/queue"
@(require) import vk "vendor:vulkan"

Sampler_Desc :: struct {
    address_mode:    vk.SamplerAddressMode,
    mag_filter:      vk.Filter,
    border_color:    vk.BorderColor,
    compare:         Maybe(vk.CompareOp),
}

Sampler_Globals :: struct {
    min_filter:     vk.Filter,
    mipmap_mode:    vk.SamplerMipmapMode,
    max_anisotropy: Maybe(f32),
    min_lod:        f32,
    max_lod:        Maybe(f32),
    lod_bias:       f32,
}

Bindless_Samplers :: struct($E: typeid) 
	where intrinsics.type_is_enum(E),
	      intrinsics.type_enum_is_contiguous(E) {
	descriptor_pool:       vk.DescriptorPool,
	descriptor_set_layout: vk.DescriptorSetLayout,
	descriptor_set:        vk.DescriptorSet,

	globals:               Sampler_Globals,
	descs:                 [E]Sampler_Desc,
	samplers:              [E]vk.Sampler,
}

Bindless_Handle :: handle_map.Handle64

Bindless_Textures :: struct {
	descriptor_pool:       vk.DescriptorPool,
	descriptor_set_layout: vk.DescriptorSetLayout,
	descriptor_set:        vk.DescriptorSet,

	capacity:              u32,
	texture_map:           handle_map.Dynamic_Handle_Map(Bindless_Slot, Bindless_Handle),
	pending_frees:         queue.Queue(Pending_Free),
}

Bindless_Slot :: struct {
	handle:  Bindless_Handle,
	texture: Texture,
	removed: bool,
}

@(private="file")
Pending_Free :: struct {
	retire_value: u64,
	handle:       Bindless_Handle,
}

default_sampler_globals :: proc() -> Sampler_Globals {
	return {
		min_filter = .LINEAR,
		mipmap_mode = .LINEAR,
		max_anisotropy = nil,
		min_lod = 0.0,
		max_lod = nil,
		lod_bias = 0.0,
	}
}

@(require_results)
bindless_samplers_init :: proc(
	samplers: ^Bindless_Samplers($E),
	device: Device, 
	descs: [E]Sampler_Desc,
	globals: Maybe(Sampler_Globals) = nil,
) -> (result: vk.Result) {
	assert(samplers != nil)

	defer if result != .SUCCESS {
		bindless_samplers_destroy(samplers, device)
	}

	sampler_count := len(E)
	samplers.descriptor_pool = create_samplers_descriptor_pool(device, sampler_count) or_return
	samplers.descriptor_set_layout = create_samplers_set_layout(device, sampler_count) or_return
	samplers.descriptor_set = create_set(
		device, 
		samplers.descriptor_pool, 
		samplers.descriptor_set_layout,
	) or_return

	sampler_globals := globals.? or_else default_sampler_globals()
	samplers.samplers = create_samplers(device, descs, sampler_globals) or_return
	samplers.globals = sampler_globals
	samplers.descs = descs
	write_samplers(device, samplers.descriptor_set, samplers.samplers)
	return
}

bindless_samplers_destroy :: proc(samplers: ^Bindless_Samplers($E), device: Device) {
	if samplers == nil {
		return
	}

	if samplers.descriptor_set_layout != 0 {
		vk.DestroyDescriptorSetLayout(device.logical, samplers.descriptor_set_layout, nil)
	}
	if samplers.descriptor_pool != 0 {
		vk.DestroyDescriptorPool(device.logical, samplers.descriptor_pool, nil)
	}
	destroy_samplers(device, &samplers.samplers)
	samplers^ = {}
}

@(require_results)
bindless_samplers_configure :: proc(
	samplers: ^Bindless_Samplers($E), 
	device: Device,
	new_globals: Sampler_Globals,
) -> vk.Result {
	vk.DeviceWaitIdle(device.logical) or_return
	new_samplers := create_samplers(device, samplers.descs, new_globals) or_return
	write_samplers(device, samplers.descriptor_set, new_samplers)
	destroy_samplers(device, &samplers.samplers)
	samplers.samplers = new_samplers
	samplers.globals = new_globals
	return .SUCCESS
}

@(private="file", require_results)
create_samplers :: proc(
	device: Device, 
	descs: [$E]Sampler_Desc, 
	globals: Sampler_Globals,
) -> (samplers: [E]vk.Sampler, result: vk.Result) {
	defer if result != .SUCCESS {
		destroy_samplers(device, &samplers)
	}

	for desc, e in descs {
		compare_op, enable_compare := desc.compare.?
		anisotropy, enable_anisotropy := globals.max_anisotropy.?
		anisotropy = clamp(anisotropy, 1.0, device.properties.limits.maxSamplerAnisotropy)
		sampler_info := vk.SamplerCreateInfo {
			sType = .SAMPLER_CREATE_INFO,
			magFilter = desc.mag_filter,
			minFilter = globals.min_filter,
			mipmapMode = globals.mipmap_mode,
			addressModeU = desc.address_mode,
			addressModeV = desc.address_mode,
			addressModeW = desc.address_mode,
			borderColor = desc.border_color,
			anisotropyEnable = b32(enable_anisotropy),
			maxAnisotropy = anisotropy,
			compareEnable = b32(enable_compare),
			compareOp = compare_op,
			minLod = globals.min_lod,
			maxLod = globals.max_lod.? or_else vk.LOD_CLAMP_NONE,
			mipLodBias = globals.lod_bias,
		}

		vk.CreateSampler(device.logical, &sampler_info, nil, &samplers[e]) or_return
	}

	return
}

@(private="file")
write_samplers :: proc(
	device: Device,
	descriptor_set: vk.DescriptorSet,
	samplers: [$E]vk.Sampler,
) where intrinsics.type_is_enum(E), intrinsics.type_enum_is_contiguous(E) {
	image_infos := [len(E)]vk.DescriptorImageInfo {}
	write_infos := [len(E)]vk.WriteDescriptorSet {}
	i := 0
	for sampler in samplers {
		image_infos[i] = {sampler = sampler}
		write_infos[i] = {
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = descriptor_set,
			dstBinding = 0,
			dstArrayElement = u32(i),
			descriptorType = .SAMPLER,
			descriptorCount = 1,
			pImageInfo = &image_infos[i],
		}
		i += 1
	}
	vk.UpdateDescriptorSets(
		device.logical, 
		u32(len(write_infos)), 
		raw_data(write_infos[:]), 
		0, nil,
	)
}

@(private="file")
destroy_samplers :: proc(device: Device, samplers: ^[$E]vk.Sampler) {
	for &sampler in samplers {
		if sampler != 0 {
			vk.DestroySampler(device.logical, sampler, nil)
			sampler = 0
		}
	}
}

@(private="file", require_results)
create_samplers_descriptor_pool :: proc(
	device: Device, 
	sampler_count: int,
) -> (descriptor_pool: vk.DescriptorPool, result: vk.Result) {
	pool_sizes := []vk.DescriptorPoolSize {
		{type = .SAMPLER, descriptorCount = u32(sampler_count)},
	}
	pool_info := vk.DescriptorPoolCreateInfo {
		sType = .DESCRIPTOR_POOL_CREATE_INFO,
		poolSizeCount = u32(len(pool_sizes)),
		pPoolSizes = raw_data(pool_sizes),
		maxSets = 1,
	}
	vk.CreateDescriptorPool(device.logical, &pool_info, nil, &descriptor_pool) or_return
	return
}

@(private="file", require_results)
create_samplers_set_layout :: proc(
	device: Device, 
	sampler_count: int,
) -> (set_layout: vk.DescriptorSetLayout, result: vk.Result) {
	bindings := []vk.DescriptorSetLayoutBinding {
		{
			binding = 0,
			descriptorType = .SAMPLER,
			descriptorCount = u32(sampler_count),
			stageFlags = {.VERTEX, .FRAGMENT},
		},
	}

	set_layout_info := vk.DescriptorSetLayoutCreateInfo {
		sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = u32(len(bindings)),
		pBindings = raw_data(bindings),
	}

	vk.CreateDescriptorSetLayout(device.logical, &set_layout_info, nil, &set_layout) or_return
	return
}

@(require_results)
bindless_init :: proc(
	textures: ^Bindless_Textures,
	device: Device, 
	capacity: int,
	allocator := context.allocator,
) -> (result: vk.Result) {
	assert(textures != nil)
	defer if result != .SUCCESS {
		bindless_destroy(textures, device)		
	}

	textures.capacity = u32(capacity)
	textures.descriptor_pool = create_table_descriptor_pool(device, capacity) or_return
	textures.descriptor_set_layout = create_table_set_layout(device, capacity) or_return
	textures.descriptor_set = create_set(
		device, 
		textures.descriptor_pool,
		textures.descriptor_set_layout,
	) or_return

	handle_map.dynamic_init(&textures.texture_map, allocator)
	queue.init(&textures.pending_frees)
	return
}

bindless_destroy :: proc(textures: ^Bindless_Textures, device: Device) {
	if textures == nil {
		return
	}
	
	if textures.descriptor_set_layout != 0 {
		vk.DestroyDescriptorSetLayout(device.logical, textures.descriptor_set_layout, nil)
	}
	if textures.descriptor_pool != 0 {
		vk.DestroyDescriptorPool(device.logical, textures.descriptor_pool, nil)
	}

	iterator := handle_map.iterator_make(&textures.texture_map)
	for slot, _ in handle_map.iterate(&iterator) {
		texture_destroy(&slot.texture, device)
	}

	handle_map.dynamic_destroy(&textures.texture_map)
	queue.destroy(&textures.pending_frees)
	textures^ = {}
}

@(require_results)
bindless_add :: proc(
	textures: ^Bindless_Textures, 
	device: Device,
	texture: Texture,
) -> (handle: Bindless_Handle, ok: bool) {
	assert(textures != nil)

	handle = handle_map.dynamic_add(&textures.texture_map, {texture = texture, removed = false})
	if handle.idx >= textures.capacity {
		handle_map.dynamic_remove(&textures.texture_map, handle)
		handle = {}
		return
	}

	image_info := vk.DescriptorImageInfo {
		imageView = texture.full_view.handle,
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
	}
	write_info := vk.WriteDescriptorSet {
		sType = .WRITE_DESCRIPTOR_SET,
		dstSet = textures.descriptor_set,
		dstBinding = 0,
		dstArrayElement = handle.idx,
		descriptorType = .SAMPLED_IMAGE,
		descriptorCount = 1,
		pImageInfo = &image_info,
	}
	vk.UpdateDescriptorSets(device.logical, 1, &write_info, 0, nil)

	return handle, true
}

bindless_remove :: proc(
	textures: ^Bindless_Textures, 
	frame_ring: Frame_Ring, 
	handle: Bindless_Handle,
) {
	assert(textures != nil)

	if slot, ok := handle_map.get(&textures.texture_map, handle); ok {
		slot.removed = true
		queue.enqueue(&textures.pending_frees, {
			retire_value = frame_ring.timeline_value + 1,
			handle = handle,
		})
	}
}

@(require_results)
bindless_get :: proc(
	textures: ^Bindless_Textures, 
	handle: Bindless_Handle,
) -> (texture: ^Texture, ok: bool) {
	assert(textures != nil)

	slot := handle_map.get(&textures.texture_map, handle) or_return
	if slot.removed {
		return nil, false	
	}
	return &slot.texture, true
}

bindless_destroy_pending :: proc(
	textures: ^Bindless_Textures, 
	device: Device, 
	finished_value: u64,
) {
	assert(textures != nil)

	for queue.len(textures.pending_frees) > 0 {
		pending_free := queue.front_ptr(&textures.pending_frees)
		if pending_free.retire_value <= finished_value {
			if slot, ok := handle_map.get(&textures.texture_map, pending_free.handle); ok {
				assert(slot.removed)
				texture_destroy(&slot.texture, device)
				handle_map.remove(&textures.texture_map, pending_free.handle)
			}
			queue.dequeue(&textures.pending_frees)
		} else {
			break	
		}
	}
}

@(private="file", require_results)
create_table_descriptor_pool :: proc(
	device: Device, 
	texture_count: int,
) -> (descriptor_pool: vk.DescriptorPool, result: vk.Result) {
	pool_sizes := []vk.DescriptorPoolSize {
		{type = .SAMPLED_IMAGE, descriptorCount = u32(texture_count)},
	}
	pool_info := vk.DescriptorPoolCreateInfo {
		sType = .DESCRIPTOR_POOL_CREATE_INFO,
		flags = {.UPDATE_AFTER_BIND},
		poolSizeCount = u32(len(pool_sizes)),
		pPoolSizes = raw_data(pool_sizes),
		maxSets = 1,
	}
	vk.CreateDescriptorPool(device.logical, &pool_info, nil, &descriptor_pool) or_return
	return
}

@(private="file", require_results)
create_table_set_layout :: proc(
	device: Device, 
	texture_count: int,
) -> (set_layout: vk.DescriptorSetLayout, result: vk.Result) {
	bindings := []vk.DescriptorSetLayoutBinding {
		{
			binding = 0,
			descriptorType = .SAMPLED_IMAGE,
			descriptorCount = u32(texture_count),
			stageFlags = {.VERTEX, .FRAGMENT},
		},
	}

	binding_flags := []vk.DescriptorBindingFlags {
		{.UPDATE_AFTER_BIND, .PARTIALLY_BOUND, .UPDATE_UNUSED_WHILE_PENDING},
	}

	binding_flags_info := vk.DescriptorSetLayoutBindingFlagsCreateInfo {
		sType = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
		bindingCount = u32(len(binding_flags)),
		pBindingFlags = raw_data(binding_flags),
	}

	set_layout_info := vk.DescriptorSetLayoutCreateInfo {
		sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		flags = {.UPDATE_AFTER_BIND_POOL},
		bindingCount = u32(len(bindings)),
		pBindings = raw_data(bindings),
		pNext = &binding_flags_info,
	}

	vk.CreateDescriptorSetLayout(device.logical, &set_layout_info, nil, &set_layout) or_return
	return
}

@(private="file")
create_set :: proc(
	device: Device, 
	pool: vk.DescriptorPool,
	layout: vk.DescriptorSetLayout,
) -> (set: vk.DescriptorSet, result: vk.Result) {
	set_layout := layout
	set_allocate_info := vk.DescriptorSetAllocateInfo {
		sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool = pool,
		descriptorSetCount = 1,
		pSetLayouts = &set_layout,
	}

	vk.AllocateDescriptorSets(device.logical, &set_allocate_info, &set) or_return
	return
}


