package main
import "core:log"
import _ "core:image/jpeg"
import _ "core:image/png"
import "core:image"
import "core:slice"
import "core:bytes"
import vk "vendor:vulkan"

Renderer :: struct {
	instance: Instance,
	device: Device,
	surface: Surface,
	frame_ring: Frame_Ring,

	pipeline_layout: vk.PipelineLayout,
	pipeline: vk.Pipeline,

	depth_texture: Texture,

	descriptor_pool: vk.DescriptorPool,
	descriptor_set_layout: vk.DescriptorSetLayout,
	descriptor_set: vk.DescriptorSet,

	instance_buffer: Buffer,
	vertex_buffer: Buffer,

	texture: Texture,
	sampler: vk.Sampler,
}

Renderer_Draw_Error :: enum {
	Texture_Acquisition_Failed,
	Presentation_Failed,
	Out_Of_Scratch_Memory,
}

Renderer_Error :: union #shared_nil {
	Instance_Error,
	Device_Error,
	Surface_Error,
	Frame_Ring_Error,
	Renderer_Draw_Error,
	Texture_Error,
	Buffer_Error,
	vk.Result,
}

View_Data :: struct {
	world_to_clip: matrix[4, 4]f32,
}

Vertex_Data :: struct {
	position: [3]f32,
	normal: [3]f32,
	tex_coords: [2]f32,
}

Instance_Data :: struct {
	object_to_world: matrix[3, 4]f32,
}

Point_Light_Data :: struct {
	position: [3]f32,
	radius: f32,
	power: f32,
	color: [3]f32,
}

Dir_Light_Data :: struct {
	direction: [3]f32,
	illuminance: f32,
	color: [3]f32,
}

Lighting_Data :: struct {
	ambient_illuminance: f32,
	ambient_color: [3]f32,
	point_lights_address: Device_Address,
	dir_lights_address: Device_Address,
	point_light_count: u32,
	dir_light_count: u32,
}

Push_Constants_Data :: struct {
	view_address: Device_Address,
	instances_address: Device_Address,
	vertices_address: Device_Address,
	lighting_address: Device_Address,
}

Frame_Data :: struct {
	view: Scratch_Ptr(View_Data),
	lighting: Scratch_Ptr(Lighting_Data),
}

@(require_results)
renderer_init :: proc(r: ^Renderer, window: ^Window) -> (err: Renderer_Error) {
	assert(r != nil)

	defer if err != nil {
		renderer_destroy(r)	
	}

	instance_init(&r.instance) or_return
	surface_init(&r.surface, r.instance, window) or_return
	device_init(&r.device, r.instance, r.surface) or_return
	frame_ring_init(&r.frame_ring, r.device) or_return
	surface_configure(&r.surface, r.device) or_return
	create_depth_texture(r) or_return
	create_descriptor_sets(r) or_return
	create_pipeline_layout(r) or_return
	create_pipeline(r) or_return
	create_buffers(r) or_return
	load_textures(r) or_return

	return nil
}

renderer_destroy :: proc (r: ^Renderer) {
	if r == nil {
		return
	}

	if r.device.logical != nil {
		_ = vk.DeviceWaitIdle(r.device.logical)
	}
	destroy_textures(r)
	destroy_buffers(r)
	destroy_pipeline(r)
	destroy_pipeline_layout(r)
	destroy_descriptor_sets(r)
	destroy_depth_texture(r)
	frame_ring_destroy(&r.frame_ring, r.device)
	surface_destroy(&r.surface, r.instance, r.device)
	device_destroy(&r.device)
	instance_destroy(&r.instance)
	r^ = {}
}

@(require_results)
renderer_draw :: proc(r: ^Renderer, scene: Scene) -> Renderer_Error {
	frame_context := frame_begin(&r.frame_ring, r.device) or_return
	frame_data, ok := write_frame_data(r^, frame_context, scene)
	if !ok {
		return Renderer_Draw_Error.Out_Of_Scratch_Memory
	}

	surface_texture, acquire_result := surface_acquire_texture(
		r.surface, 
		r.device, 
		frame_context.image_available,
	)

	needs_reconfigure := false
	#partial switch acquire_result {
	case .SUCCESS:
	case .SUBOPTIMAL_KHR:
		needs_reconfigure = true
	case .ERROR_OUT_OF_DATE_KHR:
		reconfigure_targets(r) or_return
		return nil
	case .TIMEOUT, .NOT_READY:
		return nil
	case:
		log.errorf("Failed to acquire next image: %v", acquire_result)
		return Renderer_Draw_Error.Texture_Acquisition_Failed
	}

	record_commands(r^, frame_context.command_buffer, frame_data, surface_texture)

	frame_submit(
		&r.frame_ring, r.device, 
		surface_texture.presentable, 
		frame_context,
	) or_return

	#partial switch result := surface_present(r.surface, r.device, surface_texture); result {
	case .SUCCESS:
	case .SUBOPTIMAL_KHR, .ERROR_OUT_OF_DATE_KHR:
		needs_reconfigure = true
	case:	
		log.errorf("Failed to present image: %v", result)
		return Renderer_Draw_Error.Presentation_Failed
	}

	if needs_reconfigure || surface_should_resize(r.surface) {
		reconfigure_targets(r) or_return
	}
	
	return nil
}

@(require_results)
reconfigure_targets :: proc(r: ^Renderer) -> Renderer_Error {
	vk.DeviceWaitIdle(r.device.logical) or_return

	old_format := r.surface.format
	surface_configure(&r.surface, r.device) or_return
	new_format := r.surface.format
	if old_format != new_format {
		create_pipeline(r) or_return
	}

	create_depth_texture(r) or_return
	return nil
}

@(require_results)
write_frame_data :: proc(renderer: Renderer, frame: Frame_Context, scene: Scene) -> (
	data: Frame_Data, 
	ok: bool,
) {
	width := int(renderer.surface.extent.width)
	height := int(renderer.surface.extent.height)
	view := View_Data { world_to_clip = get_world_to_clip_matrix(scene.camera, width, height) }
	data.view = scratch_new_clone(frame.scratch, view) or_return

	point_lights := scratch_make(
		frame.scratch, 
		[]Point_Light_Data, 
		count = len(scene.point_lights), 
		zeroed = false,
	) or_return

	for point_light, i in scene.point_lights {
		point_lights.data[i] = {
			position = point_light.position,
			radius = point_light.radius,
			power = point_light.power,
			color = point_light.color,
		}
	}

	dir_lights := scratch_make(
		frame.scratch, 
		[]Dir_Light_Data, 
		count = len(scene.directional_lights), 
		zeroed = false,
	) or_return

	for dir_light, i in scene.directional_lights {
		dir_lights.data[i] = {
			direction = dir_light.direction,
			illuminance = dir_light.illuminance,
			color = dir_light.color,
		}
	}

	lighting := Lighting_Data {
		ambient_color = scene.ambient_light.color,
		ambient_illuminance = scene.ambient_light.illuminance,
		point_lights_address = point_lights.address,
		point_light_count = u32(len(point_lights.data)),
		dir_lights_address = dir_lights.address,
		dir_light_count = u32(len(dir_lights.data)),
	}
	data.lighting = scratch_new_clone(frame.scratch, lighting) or_return

	return data, true
}

record_commands :: proc(
	renderer: Renderer, 
	commands: vk.CommandBuffer, 
	frame_data: Frame_Data,
	surface: Surface_Texture,
) {
	subresource_range := vk.ImageSubresourceRange {
		aspectMask = {.COLOR},
		baseMipLevel = 0,
		levelCount = 1,
		baseArrayLayer = 0,
		layerCount = 1,
	}

	record_image_barrier(commands, {
		image = renderer.depth_texture.handle,
		srcStageMask = {},
		srcAccessMask = {},
		dstStageMask = {.EARLY_FRAGMENT_TESTS},
		dstAccessMask = {.DEPTH_STENCIL_ATTACHMENT_READ, .DEPTH_STENCIL_ATTACHMENT_WRITE}, 
		oldLayout = .UNDEFINED, 
		newLayout = .DEPTH_ATTACHMENT_OPTIMAL,
		subresourceRange = vk.ImageSubresourceRange {
			aspectMask = {.DEPTH},
			baseMipLevel = 0,
			levelCount = 1,
			baseArrayLayer = 0,
			layerCount = 1,
		},
	})
	record_image_barrier(commands, {
		image = surface.texture.handle,
		srcStageMask = {},
		srcAccessMask = {},
		dstStageMask = {.COLOR_ATTACHMENT_OUTPUT},
		dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
		oldLayout = .UNDEFINED,
		newLayout = .COLOR_ATTACHMENT_OPTIMAL,
		subresourceRange = subresource_range,
	})
	record_draw_commands(renderer, commands, frame_data, surface)
	record_image_barrier(commands, {
		image = surface.texture.handle,
		srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
		srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
		dstStageMask = {},
		dstAccessMask = {},
		oldLayout = .COLOR_ATTACHMENT_OPTIMAL,
		newLayout = .PRESENT_SRC_KHR,
		subresourceRange = subresource_range,
	})
}

record_draw_commands :: proc(
	renderer: Renderer, 
	commands: vk.CommandBuffer, 
	frame_data: Frame_Data,
	surface: Surface_Texture,
) {
	color_attachment_info := vk.RenderingAttachmentInfo {
		sType = .RENDERING_ATTACHMENT_INFO,
		imageView = surface.texture.full_view.handle,
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		storeOp = .STORE,
		loadOp = .CLEAR,
		clearValue = {
			color = {
				float32 = {0.2, 0.7, 1.0, 1.0},
			},
		},
	}
	depth_attachment_info := vk.RenderingAttachmentInfo {
		sType = .RENDERING_ATTACHMENT_INFO,
		imageView = renderer.depth_texture.full_view.handle,
		imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
		storeOp = .STORE,
		loadOp = .CLEAR,
		clearValue = {
			depthStencil = {
				depth = 0.0,
			},
		},
	}
	render_info := vk.RenderingInfo {
		sType = .RENDERING_INFO,
		renderArea = {
			offset = {0, 0},
			extent = renderer.surface.extent,
		},
		layerCount = 1,
		colorAttachmentCount = 1,
		pColorAttachments = &color_attachment_info,
		pDepthAttachment = &depth_attachment_info,
	}

	vk.CmdBeginRendering(commands, &render_info)

	viewport := vk.Viewport {
		x = 0.0, 
		y = 0.0,
		width = f32(renderer.surface.extent.width),
		height = f32(renderer.surface.extent.height),
		minDepth = 0.0, 
		maxDepth = 1.0,
	}
	vk.CmdSetViewport(commands, 0, 1, &viewport)

	scissor := vk.Rect2D {
		offset = {0, 0},
		extent = renderer.surface.extent,
	}
	vk.CmdSetScissor(commands, 0, 1, &scissor)

	constants := Push_Constants_Data {
		instances_address = renderer.instance_buffer.address,
		vertices_address = renderer.vertex_buffer.address,
		view_address = frame_data.view.address,
		lighting_address = frame_data.lighting.address,
	}
	vk.CmdPushConstants(
		commands, renderer.pipeline_layout, {.VERTEX, .FRAGMENT}, 
		0, size_of(constants), &constants,
	)

	descriptor_set := renderer.descriptor_set
	vk.CmdBindPipeline(commands, .GRAPHICS, renderer.pipeline)
	vk.CmdBindDescriptorSets(commands, .GRAPHICS, renderer.pipeline_layout, 0, 1, &descriptor_set, 0, nil)
	vk.CmdDraw(commands, 
	           u32(renderer.vertex_buffer.size) / size_of(Vertex_Data),
	           u32(renderer.instance_buffer.size) / size_of(Instance_Data), 
	    	   0, 0)
	
	vk.CmdEndRendering(commands)
}

record_image_barrier :: proc(cmd: vk.CommandBuffer, barrier: vk.ImageMemoryBarrier2) {
	image_barrier := barrier
	image_barrier.sType = .IMAGE_MEMORY_BARRIER_2
	dependency_info := vk.DependencyInfo {
		sType = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers = &image_barrier,
	}
	vk.CmdPipelineBarrier2(cmd, &dependency_info)
}

@(require_results)
load_textures :: proc(r: ^Renderer) -> Renderer_Error {
	img, err := image.load_from_file("assets/rocksalbedo.jpg", {.alpha_add_if_missing})
	if err != nil {
		log.panic("failed to load image")
	}
	defer image.destroy(img)
	if img.depth != 8 || img.channels != 4 {
		log.panic("invalid image format")
	}

	pixels := bytes.buffer_to_bytes(&img.pixels)

	staging_buffer: Buffer

	buffer_init(
		&staging_buffer, r.device,
		size = slice.size(pixels), 
		memory_flags = {.MAPPED, .HOST_ACCESS_SEQUENTIAL_WRITE},
		buffer_usage = {.TRANSFER_SRC},
	) or_return
	defer buffer_destroy(&staging_buffer, r.device)
	copy(staging_buffer.mapped, pixels)
	buffer_flush(&staging_buffer, r.device) or_return

	texture_extent := vk.Extent3D {u32(img.width), u32(img.height), 1}
	texture_init(
		&r.texture, r.device,
		type = .D2,
		format = .R8G8B8A8_SRGB,
		usage = {.TRANSFER_DST, .SAMPLED},
		extent = texture_extent,
	) or_return

	sampler_info := vk.SamplerCreateInfo {
		sType = .SAMPLER_CREATE_INFO,
		magFilter = .NEAREST,
		minFilter = .LINEAR,
		mipmapMode = .LINEAR,
		addressModeU = .REPEAT,
		addressModeV = .REPEAT,
		addressModeW = .REPEAT,
		minLod = 0.0,
		maxLod = 128.0,
	}

	vk.CreateSampler(r.device.logical, &sampler_info, nil, &r.sampler) or_return

	subresource_range := view_subresource_range(r.texture.full_view)

	cmd := begin_quick_command_buffer(r.frame_ring) or_return

	record_image_barrier(cmd, {
		image = r.texture.handle,
		srcStageMask = {},
		srcAccessMask = {},
		dstStageMask = {.TRANSFER},
		dstAccessMask = {.TRANSFER_WRITE},
		oldLayout = .UNDEFINED,
		newLayout = .TRANSFER_DST_OPTIMAL,
		subresourceRange = subresource_range,
	})

	image_copy := vk.BufferImageCopy {
		imageOffset = {0, 0, 0},
		imageExtent = r.texture.extent,
		imageSubresource = {
			aspectMask = r.texture.full_view.aspect_mask,
			baseArrayLayer = 0,
			layerCount = 1,
			mipLevel = 0,
		},
	}
	vk.CmdCopyBufferToImage(
		cmd, staging_buffer.handle, 
		r.texture.handle, .TRANSFER_DST_OPTIMAL,
		1, &image_copy,
	)

	record_image_barrier(cmd, {
		image = r.texture.handle,
		srcStageMask = {.TRANSFER},
		srcAccessMask = {.TRANSFER_WRITE},
		dstStageMask = {.FRAGMENT_SHADER},
		dstAccessMask = {.SHADER_SAMPLED_READ},
		oldLayout = .TRANSFER_DST_OPTIMAL,
		newLayout = .SHADER_READ_ONLY_OPTIMAL,
		subresourceRange = subresource_range,
	})

	submit_quick_command_buffer(r.frame_ring, r.device) or_return

	desc_image_info := vk.DescriptorImageInfo {
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
		imageView = r.texture.full_view.handle,
		sampler = r.sampler,
	}
	write_image := vk.WriteDescriptorSet {
		sType = .WRITE_DESCRIPTOR_SET,
		dstSet = r.descriptor_set,
		dstBinding = 0,
		dstArrayElement = 0,
		descriptorCount = 1,
		descriptorType = .COMBINED_IMAGE_SAMPLER,
		pImageInfo = &desc_image_info,
	}

	vk.UpdateDescriptorSets(r.device.logical, 1, &write_image, 0, nil)
	return nil
}

destroy_textures :: proc(r: ^Renderer) {
	if r.sampler != 0 {
		vk.DestroySampler(r.device.logical, r.sampler, nil)
		r.sampler = 0
	}
	texture_destroy(&r.texture, r.device)
}


@(require_results)
create_buffers :: proc(r: ^Renderer) -> Buffer_Error {
	vertices := []Vertex_Data {
		// -Z
		{{-0.5, -0.5, -0.5}, {0.0, 0.0, -1.0}, {0.0, 1.0}},
		{{0.5, -0.5, -0.5}, {0.0, 0.0, -1.0}, {1.0, 1.0}},
		{{0.5, 0.5, -0.5}, {0.0, 0.0, -1.0}, {1.0, 0.0}},
		{{-0.5, -0.5, -0.5}, {0.0, 0.0, -1.0}, {0.0, 1.0}},
		{{0.5, 0.5, -0.5}, {0.0, 0.0, -1.0}, {1.0, 0.0}},
		{{-0.5, 0.5, -0.5}, {0.0, 0.0, -1.0}, {0.0, 0.0}},
		// +Z
		{{0.5, -0.5, 0.5}, {0.0, 0.0, 1.0}, {0.0, 1.0}},
		{{-0.5, -0.5, 0.5}, {0.0, 0.0, 1.0}, {1.0, 1.0}},
		{{-0.5, 0.5, 0.5}, {0.0, 0.0, 1.0}, {1.0, 0.0}},
		{{0.5, -0.5, 0.5}, {0.0, 0.0, 1.0}, {0.0, 1.0}},
		{{-0.5, 0.5, 0.5}, {0.0, 0.0, 1.0}, {1.0, 0.0}},
		{{0.5, 0.5, 0.5}, {0.0, 0.0, 1.0}, {0.0, 0.0}},
		// +X
		{{0.5, -0.5, -0.5}, {1.0, 0.0, 0.0}, {0.0, 1.0}},
		{{0.5, -0.5, 0.5}, {1.0, 0.0, 0.0}, {1.0, 1.0}},
		{{0.5, 0.5, 0.5}, {1.0, 0.0, 0.0}, {1.0, 0.0}},
		{{0.5, -0.5, -0.5}, {1.0, 0.0, 0.0}, {0.0, 1.0}},
		{{0.5, 0.5, 0.5}, {1.0, 0.0, 0.0}, {1.0, 0.0}},
		{{0.5, 0.5, -0.5}, {1.0, 0.0, 0.0}, {0.0, 0.0}},
		// -X
		{{-0.5, -0.5, 0.5}, {-1.0, 0.0, 0.0}, {0.0, 1.0}},
		{{-0.5, -0.5, -0.5}, {-1.0, 0.0, 0.0}, {1.0, 1.0}},
		{{-0.5, 0.5, -0.5}, {-1.0, 0.0, 0.0}, {1.0, 0.0}},
		{{-0.5, -0.5, 0.5}, {-1.0, 0.0, 0.0}, {0.0, 1.0}},
		{{-0.5, 0.5, -0.5}, {-1.0, 0.0, 0.0}, {1.0, 0.0}},
		{{-0.5, 0.5, 0.5}, {-1.0, 0.0, 0.0}, {0.0, 0.0}},
		// +Y
		{{-0.5, 0.5, -0.5}, {0.0, 1.0, 0.0}, {0.0, 1.0}},
		{{0.5, 0.5, -0.5}, {0.0, 1.0, 0.0}, {1.0, 1.0}},
		{{0.5, 0.5, 0.5}, {0.0, 1.0, 0.0}, {1.0, 0.0}},
		{{-0.5, 0.5, -0.5}, {0.0, 1.0, 0.0}, {0.0, 1.0}},
		{{0.5, 0.5, 0.5}, {0.0, 1.0, 0.0}, {1.0, 0.0}},
		{{-0.5, 0.5, 0.5}, {0.0, 1.0, 0.0}, {0.0, 0.0}},
		// -Y
		{{0.5, -0.5, -0.5}, {0.0, -1.0, 0.0}, {0.0, 1.0}},
		{{-0.5, -0.5, -0.5}, {0.0, -1.0, 0.0}, {1.0, 1.0}},
		{{-0.5, -0.5, 0.5}, {0.0, -1.0, 0.0}, {1.0, 0.0}},
		{{0.5, -0.5, -0.5}, {0.0, -1.0, 0.0}, {0.0, 1.0}},
		{{-0.5, -0.5, 0.5}, {0.0, -1.0, 0.0}, {1.0, 0.0}},
		{{0.5, -0.5, 0.5}, {0.0, -1.0, 0.0}, {0.0, 0.0}},
	}

	instances := make([dynamic]Instance_Data, 0, 0, context.temp_allocator)

	rows := 10
	columns := 10
	spacing := f32(3.0)
	for a in 0..<rows {
		for b in 0..<columns {
			transform := affine_make({
				(f32(a) - f32(rows) * 0.5 + 0.5) * spacing, -1.0, 
				(f32(b) - f32(columns) * 0.5 + 0.5) * spacing,
			})
			append(&instances, Instance_Data {
				object_to_world = affine_to_matrix3x4(transform),
			})
		}
	}

	buffer_init(
		&r.vertex_buffer, r.device, 
		size = slice.size(vertices),
		buffer_usage = {.SHADER_DEVICE_ADDRESS, .STORAGE_BUFFER},
		memory_flags = {.MAPPED, .HOST_ACCESS_SEQUENTIAL_WRITE},
	) or_return

	buffer_init(
		&r.instance_buffer, r.device, 
		size = slice.size(instances[:]),
		buffer_usage = {.SHADER_DEVICE_ADDRESS, .STORAGE_BUFFER},
		memory_flags = {.MAPPED, .HOST_ACCESS_SEQUENTIAL_WRITE},
	) or_return

	mapped_vertices := slice.reinterpret([]Vertex_Data, r.vertex_buffer.mapped)
	copy(mapped_vertices, vertices)
	buffer_flush(&r.vertex_buffer, r.device) or_return

	mapped_instances := slice.reinterpret([]Instance_Data, r.instance_buffer.mapped)
	copy(mapped_instances, instances[:])
	buffer_flush(&r.instance_buffer, r.device) or_return

	return nil
}

destroy_buffers :: proc(r: ^Renderer) {
	buffer_destroy(&r.instance_buffer, r.device)
	buffer_destroy(&r.vertex_buffer, r.device)
}

@(require_results)
create_depth_texture :: proc(r: ^Renderer) -> Texture_Error {
	texture_destroy(&r.depth_texture, r.device)

	depth_extent := vk.Extent3D {
		r.surface.extent.width,
		r.surface.extent.height, 1,
	}

	texture_init(
		&r.depth_texture, r.device,
		type = .D2,
		format = .D32_SFLOAT,
		usage = {.DEPTH_STENCIL_ATTACHMENT},
		extent = depth_extent,
	) or_return

	return nil
}

destroy_depth_texture :: proc(r: ^Renderer) {
	texture_destroy(&r.depth_texture, r.device)
}

@(require_results)
create_descriptor_sets :: proc(r: ^Renderer) -> vk.Result {
	pool_sizes := []vk.DescriptorPoolSize {
		{
			type = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = 1,
		},
	}
	pool_info := vk.DescriptorPoolCreateInfo {
		sType = .DESCRIPTOR_POOL_CREATE_INFO,
		maxSets = 1,
		poolSizeCount = u32(len(pool_sizes)),
		pPoolSizes = raw_data(pool_sizes),
	}

	vk.CreateDescriptorPool(r.device.logical, &pool_info, nil, &r.descriptor_pool) or_return

	bindings := []vk.DescriptorSetLayoutBinding {
		{
			binding = 0,
			descriptorType = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = 1,
			stageFlags = {.FRAGMENT},
		},
	}
	layout_info := vk.DescriptorSetLayoutCreateInfo {
		sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = u32(len(bindings)),
		pBindings = raw_data(bindings),
	}

	vk.CreateDescriptorSetLayout(
		r.device.logical, &layout_info, nil, 
		&r.descriptor_set_layout,
	) or_return

	set_alloc_info := vk.DescriptorSetAllocateInfo {
		sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool = r.descriptor_pool,
		descriptorSetCount = 1,
		pSetLayouts = &r.descriptor_set_layout,
	}

	vk.AllocateDescriptorSets(
		r.device.logical, &set_alloc_info,
		&r.descriptor_set,
	) or_return

	return .SUCCESS
}

destroy_descriptor_sets :: proc(r: ^Renderer) {
	if r.descriptor_set_layout != 0 {
		vk.DestroyDescriptorSetLayout(r.device.logical, r.descriptor_set_layout, nil)
		r.descriptor_set_layout = 0
	}
	if r.descriptor_pool != 0 {
		vk.DestroyDescriptorPool(r.device.logical, r.descriptor_pool, nil)
		r.descriptor_pool = 0
	}
}

@(require_results)
create_pipeline_layout :: proc(r: ^Renderer) -> vk.Result {
	push_constant_range := vk.PushConstantRange {
		stageFlags = {.VERTEX, .FRAGMENT},
		offset = 0,
		size = u32(size_of(Push_Constants_Data)),
	}
	layout_info := vk.PipelineLayoutCreateInfo {
		sType = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount = 1,
		pSetLayouts = &r.descriptor_set_layout,
		pushConstantRangeCount = 1,
		pPushConstantRanges = &push_constant_range,
	}

	return vk.CreatePipelineLayout(r.device.logical, &layout_info, nil, &r.pipeline_layout)
}

@(require_results)
create_pipeline :: proc(r: ^Renderer) -> vk.Result {
	SHADER_SPIRV :: #load("shaders/compiled/default.spv")
	shader_module: vk.ShaderModule
	shader_module_info := vk.ShaderModuleCreateInfo {
		sType = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(SHADER_SPIRV),
		pCode = cast([^]u32)raw_data(SHADER_SPIRV),
	}

	vk.CreateShaderModule(
		r.device.logical, 
		&shader_module_info, nil, 
		&shader_module,
	) or_return

	defer if shader_module != 0 {
		vk.DestroyShaderModule(r.device.logical, shader_module, nil)
	}

	shader_stages := []vk.PipelineShaderStageCreateInfo {
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.VERTEX},
			module = shader_module,
			pName = "vertex_main",
		},
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.FRAGMENT},
			module = shader_module,
			pName = "fragment_main",
		},
	}

	vertex_state := vk.PipelineVertexInputStateCreateInfo {
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
	}

	input_assembly_state := vk.PipelineInputAssemblyStateCreateInfo {
		sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_LIST,
	}

	raster_state := vk.PipelineRasterizationStateCreateInfo {
		sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		lineWidth = 1,
		polygonMode = .FILL,
		cullMode = {.BACK},
		frontFace = .COUNTER_CLOCKWISE,
	}

	depth_stencil_state := vk.PipelineDepthStencilStateCreateInfo {
		sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		depthTestEnable = true,
		depthWriteEnable = true,
		depthCompareOp = .GREATER_OR_EQUAL,
	}

	viewport_state := vk.PipelineViewportStateCreateInfo {
		sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount = 1,
	}

	sample_mask := ~vk.SampleMask(0)
	ms_state := vk.PipelineMultisampleStateCreateInfo {
		sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		pSampleMask = &sample_mask,
		rasterizationSamples = {._1},
	}

	blend_attachment := vk.PipelineColorBlendAttachmentState {
		colorWriteMask = {.R, .G, .B, .A},
	}

	blend_state := vk.PipelineColorBlendStateCreateInfo {
		sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments = &blend_attachment,
	}

	dynamic_states := []vk.DynamicState {.VIEWPORT, .SCISSOR}
	dynamic_state := vk.PipelineDynamicStateCreateInfo {
		sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = u32(len(dynamic_states)),
		pDynamicStates = raw_data(dynamic_states),
	}

	color_attachment_format := r.surface.format
	rendering_info := vk.PipelineRenderingCreateInfo {
		sType = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount = 1,
		pColorAttachmentFormats = &color_attachment_format,
		depthAttachmentFormat = r.depth_texture.format,
	}

	pipeline_info := vk.GraphicsPipelineCreateInfo {
		sType = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext = rawptr(&rendering_info),
		layout = r.pipeline_layout,
		stageCount = 2,
		pStages = raw_data(shader_stages),
		pVertexInputState = &vertex_state,
		pInputAssemblyState = &input_assembly_state,
		pRasterizationState = &raster_state,
		pDepthStencilState = &depth_stencil_state,
		pViewportState = &viewport_state,
		pMultisampleState = &ms_state,
		pColorBlendState = &blend_state,
		pDynamicState = &dynamic_state,
	}

	pipeline: vk.Pipeline
	vk.CreateGraphicsPipelines(r.device.logical, 0, 1, &pipeline_info, nil, &pipeline) or_return

	destroy_pipeline(r)
	r.pipeline = pipeline
	return nil
}

destroy_pipeline_layout :: proc(r: ^Renderer) {
	if r.pipeline_layout != 0 {
		vk.DestroyPipelineLayout(r.device.logical, r.pipeline_layout, nil)
		r.pipeline_layout = 0
	}
}

destroy_pipeline :: proc(r: ^Renderer) {
	if r.pipeline != 0 {
		vk.DestroyPipeline(r.device.logical, r.pipeline, nil)
		r.pipeline = 0
	}
}

