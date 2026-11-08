package main
import "core:log"
import "core:sort"
import "core:mem"
import "core:mem/virtual"
import "base:runtime"
import vk "vendor:vulkan"

STAGING_CAPACITY :: 128 * 1024 * 1024
SCRATCH_CAPACITY :: 16 * 1024 * 1024
MESH_POOL_CAPACITY :: 128 * 1024 * 1024
INDEX_POOL_CAPACITY :: 128 * 1024 * 1024
ARENA_CAPACITY :: 128 * mem.Megabyte
TEXTURES_CAPACITY :: 65536

Renderer :: struct {
	instance: Instance,
	device: Device,
	surface: Surface,
	frame_ring: Frame_Ring,
	upload_queue: Upload_Queue,
	meshes: Meshes,
	textures: Textures,
	arena: virtual.Arena,

	texture_handle: Texture_Handle,

	pipeline_layout: vk.PipelineLayout,
	pipeline: vk.Pipeline,

	depth_texture: Texture,
}

Renderer_Draw_Error :: enum {
	None = 0,
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
	runtime.Allocator_Error,
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
	point_light_count: u32,
	dir_lights_address: Device_Address,
	dir_light_count: u32,
}

Push_Constants_Data :: struct {
	view_address: Device_Address,
	draws_address: Device_Address,
	instances_address: Device_Address,
	lighting_address: Device_Address,
}

Frame_Data :: struct {
	clear_color: [4]f32,
	view: Scratch_Subbuffer(View_Data),
	indexed_draws: Scratch_Subbuffer(Draw_Data),
	non_indexed_draws: Scratch_Subbuffer(Draw_Data),
	lighting: Scratch_Subbuffer(Lighting_Data),
	instances: Scratch_Subbuffer(Instance_Data),
	indexed_commands: Scratch_Subbuffer(vk.DrawIndexedIndirectCommand),
	non_indexed_commands: Scratch_Subbuffer(vk.DrawIndirectCommand),
}

Draw_Data :: struct {
	mesh_record_address: Device_Address,
	instance_offset: u32,
}

Object_Id :: struct {
	draw_key: Draw_Key,
	mesh_handle: Mesh_Handle,
	object_index: int,
}

Draw_Key :: distinct u64

make_draw_key :: proc(pipeline: u16, indexed: bool, handle: Mesh_Handle) -> Draw_Key {
	return Draw_Key((u64(pipeline) << 33) | (u64(indexed) << 32) | u64(handle.idx))
}

@(require_results)
renderer_init :: proc(r: ^Renderer, window: ^Window) -> (err: Renderer_Error) {
	assert(r != nil)

	defer if err != nil {
		renderer_destroy(r)	
	}

	virtual.arena_init_static(&r.arena, reserved = ARENA_CAPACITY) or_return
	instance_init(&r.instance) or_return
	surface_init(&r.surface, r.instance, window) or_return
	device_init(&r.device, r.instance, r.surface) or_return
	frame_ring_init(&r.frame_ring, r.device, SCRATCH_CAPACITY) or_return
	upload_queue_init(&r.upload_queue, r.device, STAGING_CAPACITY) or_return
	meshes_init(&r.meshes, r.device, MESH_POOL_CAPACITY, INDEX_POOL_CAPACITY) or_return
	textures_init(
		&r.textures, r.device, 
		&r.upload_queue, r.frame_ring, 
		TEXTURES_CAPACITY,
	) or_return

	surface_configure(&r.surface, r.device) or_return
	create_depth_texture(r) or_return
	create_pipeline_layout(r) or_return
	create_pipeline(r) or_return
	return nil
}

renderer_destroy :: proc (r: ^Renderer) {
	if r == nil {
		return
	}

	if r.device.logical != nil {
		_ = vk.DeviceWaitIdle(r.device.logical)
	}
	destroy_pipeline(r)
	destroy_pipeline_layout(r)
	destroy_depth_texture(r)

	textures_destroy(&r.textures, r.device)
	meshes_destroy(&r.meshes, r.device)
	upload_queue_destroy(&r.upload_queue, r.device)
	frame_ring_destroy(&r.frame_ring, r.device)
	surface_destroy(&r.surface, r.instance, r.device)
	device_destroy(&r.device)
	instance_destroy(&r.instance)
	virtual.arena_destroy(&r.arena)
	r^ = {}
}

@(require_results)
renderer_add_mesh :: proc(r: ^Renderer, mesh: Mesh) -> (Mesh_Handle, Mesh_Error) {
	return meshes_add(&r.meshes, &r.upload_queue, r.frame_ring, mesh)
}

renderer_replace_mesh :: proc(r: ^Renderer, handle: Mesh_Handle, mesh: Mesh) -> Mesh_Error {
	return meshes_replace(&r.meshes, &r.upload_queue, r.frame_ring, handle, mesh)
}

renderer_destroy_mesh :: proc(r: ^Renderer, handle: Mesh_Handle) {
	meshes_remove(&r.meshes, r.frame_ring, handle)
}

@(require_results)
renderer_reserve_texture :: proc(
	r: ^Renderer, 
	fallback := Texture_Fallback.Color_Default,
) -> Texture_Handle {
	return textures_reserve(&r.textures, fallback)
}

// This function returns a valid handle even when there is an error
@(require_results)
renderer_add_texture :: proc(
	r: ^Renderer, 
	image: Image, 
	srgb := true,
	fallback := Texture_Fallback.Color_Error,
) -> (Texture_Handle, Texture_Error) {
	return textures_add(
		&r.textures, r.device, 
		&r.upload_queue, r.frame_ring,
		image, srgb, fallback,
	)
}

renderer_replace_texture :: proc(
	r: ^Renderer, 
	handle: Texture_Handle, 
	image: Image,
	srgb := true,
) -> Texture_Error {
	return textures_replace(
		&r.textures, r.device,
		&r.upload_queue, r.frame_ring,
		handle, image, srgb,
	)
}

renderer_destroy_texture :: proc(r: ^Renderer, handle: Texture_Handle) {
	textures_remove(&r.textures, r.frame_ring, handle)
}

renderer_set_texture_sampler_options :: proc(r: ^Renderer, options: Texture_Sampler_Options) {
	textures_set_sampler_options(&r.textures, options)
}

@(require_results)
renderer_draw :: proc(r: ^Renderer, scene: Scene) -> Renderer_Error {
	free_all(virtual.arena_allocator(&r.arena))
	context.temp_allocator = virtual.arena_allocator(&r.arena)

	frame_context := frame_begin(&r.frame_ring, r.device) or_return
	frame_data, ok := write_frame_data(r, frame_context, scene)
	if !ok {
		return Renderer_Draw_Error.Out_Of_Scratch_Memory
	}

	clear(&r.textures.updated)
	textures_reconfigure_dirty_samplers(&r.textures, r.device) or_return

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

	upload_queue_record_commands(&r.upload_queue, frame_context.command_buffer)
	record_commands(r^, frame_context.command_buffer, frame_data, surface_texture)

	textures_destroy_pending(&r.textures, r.device, frame_context.finished_timeline_value)
	meshes_destroy_pending(&r.meshes, frame_context.finished_timeline_value)
	upload_queue_retire(&r.upload_queue, frame_context.finished_timeline_value)
	upload_queue_flush(&r.upload_queue, r.device) or_return
	frame_submit(
		&r.frame_ring, 
		r.device, 
		frame_context,
		surface_texture.presentable, 
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
write_frame_data :: proc(renderer: ^Renderer, frame: Frame_Context, scene: Scene) -> (
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

	scratch_objects := make([dynamic]Object_Id, 0, len(scene.mesh_objects), context.temp_allocator)
	for mesh_object, index in scene.mesh_objects {
		if meshes_is_valid_handle(&renderer.meshes, mesh_object.mesh) {
			pipeline := u16(0)
			indexed := meshes_is_indexed(&renderer.meshes, mesh_object.mesh)
			draw_key := make_draw_key(pipeline, indexed, mesh_object.mesh)
			append(&scratch_objects, {
				draw_key = draw_key,
				mesh_handle = mesh_object.mesh,
				object_index = index,
			})
		}
	}
	
	sort.quick_sort_proc(scratch_objects[:], proc(a, b: Object_Id) -> int {
		switch {
		case a.draw_key > b.draw_key: return 1
		case a.draw_key < b.draw_key: return -1
		case: return 0
		}
	})

	indexed_draws := make([dynamic]Draw_Data, context.temp_allocator)
	non_indexed_draws := make([dynamic]Draw_Data, context.temp_allocator)
	indexed_commands := make([dynamic]vk.DrawIndexedIndirectCommand, context.temp_allocator)
	non_indexed_commands := make([dynamic]vk.DrawIndirectCommand, context.temp_allocator)
	for i := 0; i < len(scratch_objects); {
		draw_start := i
		draw_key := scratch_objects[i].draw_key
		for i < len(scratch_objects) && scratch_objects[i].draw_key == draw_key {
			i += 1
		}

		instance_count := i - draw_start
		mesh_info, mesh_ok := meshes_get_info(&renderer.meshes, scratch_objects[draw_start].mesh_handle)
		assert(mesh_ok)
		
		draw := Draw_Data {
			mesh_record_address = mesh_info.record_address,
			instance_offset = u32(draw_start),
		}
		if mesh_info.index_count > 0 {
			append(&indexed_draws, draw)
			append(&indexed_commands, {
				firstIndex = mesh_info.first_index,
				indexCount = mesh_info.index_count,
				instanceCount = u32(instance_count),
				vertexOffset = 0,
				firstInstance = 0,
			})
		} else {
			append(&non_indexed_draws, draw)
			append(&non_indexed_commands, {
				vertexCount = mesh_info.vertex_count,
				instanceCount = u32(instance_count),
				firstVertex = 0,
				firstInstance = 0,
			})
		}
	}
	data.indexed_draws = scratch_slice_clone(frame.scratch, indexed_draws[:]) or_return
	data.non_indexed_draws = scratch_slice_clone(frame.scratch, non_indexed_draws[:]) or_return
	data.indexed_commands = scratch_slice_clone(frame.scratch, indexed_commands[:]) or_return
	data.non_indexed_commands = scratch_slice_clone(frame.scratch, non_indexed_commands[:]) or_return

	data.instances = scratch_make(frame.scratch, []Instance_Data, len(scratch_objects)) or_return
	for scratch_object, i in scratch_objects {
		object := scene.mesh_objects[scratch_object.object_index]	
		data.instances.data[i] = Instance_Data {
			object_to_world = affine_to_matrix3x4(object.transform),
		}
	}

	data.clear_color = scene.clear_color
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
		srcStageMask = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
		srcAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE}, 
		dstStageMask = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
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
		srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
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
		clearValue = {color = {float32 = frame_data.clear_color}},
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
		view_address = frame_data.view.address,
		lighting_address = frame_data.lighting.address,
		instances_address = frame_data.instances.address,
	}

	descriptor_sets := []vk.DescriptorSet {
		textures_get_sampler_set(renderer.textures),
		textures_get_texture_set(renderer.textures),
	}
	vk.CmdBindDescriptorSets(
		commands, .GRAPHICS, 
		renderer.pipeline_layout, 
		0, u32(len(descriptor_sets)), raw_data(descriptor_sets), 
		0, nil,
	)

	vk.CmdBindPipeline(commands, .GRAPHICS, renderer.pipeline)
	vk.CmdBindIndexBuffer(commands, meshes_get_index_buffer(renderer.meshes).handle, 0, .UINT32)
	if len(frame_data.indexed_commands.data) > 0 {
		constants.draws_address = frame_data.indexed_draws.address
		vk.CmdPushConstants(
			commands, renderer.pipeline_layout, {.VERTEX, .FRAGMENT}, 
			0, size_of(constants), &constants,
		)
		vk.CmdDrawIndexedIndirect(
			commands, 
			frame_data.indexed_commands.buffer_handle,
			frame_data.indexed_commands.offset,
			u32(len(frame_data.indexed_commands.data)),
			size_of(vk.DrawIndexedIndirectCommand),
		)
	}
	if len(frame_data.non_indexed_commands.data) > 0 {
		constants.draws_address = frame_data.non_indexed_draws.address
		vk.CmdPushConstants(
			commands, renderer.pipeline_layout, {.VERTEX, .FRAGMENT}, 
			0, size_of(constants), &constants,
		)
		vk.CmdDrawIndirect(
			commands,
			frame_data.non_indexed_commands.buffer_handle,
			frame_data.non_indexed_commands.offset,
			u32(len(frame_data.non_indexed_commands.data)),
			size_of(vk.DrawIndirectCommand),
		)
	}
	
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

/*
@(require_results)
load_textures :: proc(r: ^Renderer) -> Renderer_Error {
	image, err := image_load_from_file("assets/rocksalbedo.jpg")
	if err != nil {
		log.panic("failed to load image") // ok to panic here since this is temporary code
	}
	defer image_destroy(&image)

	/*
	texture: Texture
	texture_init(
		&texture, r.device,
		type = .D2,
		format = image_format_to_vk(image.format, srgb=true),
		usage = {.TRANSFER_DST, .SAMPLED},
		extent = {u32(image.width), u32(image.height), 1},
	) or_return

	ok: bool

	r.texture_handle, ok = bindless_add(&r.bindless_textures, r.device, texture)
	if !ok {
		texture_destroy(&texture, r.device)
		log.panic("Failed to add texture to bindless table")
	}

	ok = upload_texture(
		&r.upload_queue, 
		r.frame_ring, 
		texture, image,
		{ 
			stages = {.FRAGMENT_SHADER},
			access = {.SHADER_SAMPLED_READ},
			layout = .SHADER_READ_ONLY_OPTIMAL,
		},
	)
	if !ok {
		log.panic("Failed to upload texture")
	}
	*/

	return nil
}
*/

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
create_pipeline_layout :: proc(r: ^Renderer) -> vk.Result {
	set_layouts := []vk.DescriptorSetLayout {
		textures_get_sampler_set_layout(r.textures),
		textures_get_texture_set_layout(r.textures),
	}
	push_constant_range := vk.PushConstantRange {
		stageFlags = {.VERTEX, .FRAGMENT},
		offset = 0,
		size = u32(size_of(Push_Constants_Data)),
	}
	layout_info := vk.PipelineLayoutCreateInfo {
		sType = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount = u32(len(set_layouts)),
		pSetLayouts = raw_data(set_layouts),
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

