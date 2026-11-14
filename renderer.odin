package main
import "base:runtime"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:sort"
import vk "vendor:vulkan"

STAGING_CAPACITY :: 128 * mem.Megabyte
SCRATCH_CAPACITY :: 64 * mem.Megabyte
MATERIAL_POOL_CAPACITY :: 64 * mem.Megabyte
MESH_POOL_CAPACITY :: 128 * mem.Megabyte
INDEX_POOL_CAPACITY :: 128 * mem.Megabyte
ARENA_CAPACITY :: 128 * mem.Megabyte
TEXTURES_CAPACITY :: 65536

Renderer :: struct {
	instance:       Instance,
	device:         Device,
	surface:        Surface,
	frame_ring:     Frame_Ring,
	upload_queue:   Upload_Queue,
	mipgen_queue:   Mipgen_Queue,
	meshes:         Meshes,
	textures:       Textures,
	materials:      Materials,
	shaders:        Shaders,
	pipelines:      Pipelines,
	passes:         Passes,
	arena:          virtual.Arena,
	forward_pass:   Pass_Kind_Id,
	forward_target: Graphics_Target_Id,
	depth_texture:  Texture,
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
	Materials_Create_Error,
	Renderer_Draw_Error,
	Texture_Error,
	Buffer_Error,
	runtime.Allocator_Error,
	vk.Result,
}

View_Data :: struct {
	world_to_clip: matrix[4, 4]f32,
	position:      [3]f32,
}

Vertex_Data :: struct {
	position:   [3]f32,
	normal:     [3]f32,
	tex_coords: [2]f32,
}

Instance_Data :: struct {
	object_to_world:  matrix[3, 4]f32,
	material_address: Device_Address,
	material_type:    Material_Type_Id,
}

Point_Light_Data :: struct {
	position: [3]f32,
	radius:   f32,
	power:    f32,
	color:    [3]f32,
}

Dir_Light_Data :: struct {
	direction:   [3]f32,
	illuminance: f32,
	color:       [3]f32,
}

Lighting_Data :: struct {
	ambient_illuminance:  f32,
	ambient_color:        [3]f32,
	point_lights_address: Device_Address,
	point_light_count:    u32,
	dir_lights_address:   Device_Address,
	dir_light_count:      u32,
}

Push_Constants_Data :: struct {
	view_address:      Device_Address,
	draws_address:     Device_Address,
	instances_address: Device_Address,
	lighting_address:  Device_Address,
}

Frame_Data :: struct {
	clear_color:          [4]f32,
	view:                 Scratch_Subbuffer(View_Data),
	indexed_draws:        Scratch_Subbuffer(Draw_Data),
	non_indexed_draws:    Scratch_Subbuffer(Draw_Data),
	lighting:             Scratch_Subbuffer(Lighting_Data),
	instances:            Scratch_Subbuffer(Instance_Data),
	indexed_commands:     Scratch_Subbuffer(vk.DrawIndexedIndirectCommand),
	non_indexed_commands: Scratch_Subbuffer(vk.DrawIndirectCommand),
	batches:              []Draw_Batch,
}

Draw_Data :: struct {
	mesh_record_address: Device_Address,
	instance_offset:     u32,
}

Draw_Batch :: struct {
	pipeline:      Graphics_Pipeline_Id,
	indexed:       bool,
	first_command: u32,
	command_count: u32,
}

Object_Id :: struct {
	draw_key:     Draw_Key,
	pipeline:     Graphics_Pipeline_Id,
	mesh_handle:  Mesh_Handle,
	object_index: int,
}

Draw_Key :: distinct u64

make_draw_key :: proc(
	pipeline: Graphics_Pipeline_Id,
	indexed: bool,
	handle: Mesh_Handle,
) -> Draw_Key {
	return Draw_Key((u64(pipeline) << 33) | (u64(indexed) << 32) | u64(handle.idx))
}

@(require_results)
renderer_create :: proc(window: ^Window) -> (r: ^Renderer, err: Renderer_Error) {
	defer if err != nil {
		renderer_destroy(r)
	}

	r = new(Renderer)

	virtual.arena_init_static(&r.arena, reserved = ARENA_CAPACITY) or_return
	instance_init(&r.instance) or_return
	surface_init(&r.surface, r.instance, window) or_return
	device_init(&r.device, r.instance, r.surface) or_return

	frame_ring_init(&r.frame_ring, r.device, SCRATCH_CAPACITY) or_return
	upload_queue_init(&r.upload_queue, r.device, STAGING_CAPACITY) or_return
	mipgen_queue_init(&r.mipgen_queue)

	shaders_init(&r.shaders)
	meshes_init(&r.meshes, r.device, MESH_POOL_CAPACITY, INDEX_POOL_CAPACITY) or_return
	materials_init(&r.materials, r.device, MATERIAL_POOL_CAPACITY) or_return
	textures_init(
		&r.textures,
		r.device,
		&r.mipgen_queue,
		&r.upload_queue,
		r.frame_ring,
		TEXTURES_CAPACITY,
	) or_return

	set_layouts := get_set_layouts(r)
	push_constant_ranges := get_push_constant_ranges()
	pipelines_init(&r.pipelines, r.device, set_layouts[:], push_constant_ranges[:]) or_return
	passes_init(&r.passes, &r.shaders, &r.pipelines, &r.materials)

	MODULE_SPIRV :: #load("shaders/compiled/forward.spv", []u32)
	shaders_load_module(&r.shaders, r.device, "Forward", MODULE_SPIRV) or_return
	renderer_register_material_type(
		r,
		Lambert_Material,
		Lambert_Material_Data,
		name = "LambertMaterial",
		resolve = resolve_lambert,
	)
	renderer_register_material_type(
		r,
		Unlit_Material,
		Unlit_Material_Data,
		name = "UnlitMaterial",
		resolve = resolve_unlit,
	)

	surface_configure(&r.surface, r.device) or_return
	create_depth_texture(r) or_return

	r.forward_target = pipelines_add_target(
		&r.pipelines,
		{color = {r.surface.format}, depth = .D32_SFLOAT, samples = ._1},
	)

	r.forward_pass = passes_add_kind(
		&r.passes,
		r.device,
		{
			name = "Forward",
			target = r.forward_target,
			base_state = {depth_test = .Closer_Or_Equal, depth_write = true},
			select = forward_select,
		},
	)

	return r, nil
}

@(private = "file")
get_set_layouts :: proc(renderer: ^Renderer) -> [2]vk.DescriptorSetLayout {
	return {
		textures_get_sampler_set_layout(renderer.textures),
		textures_get_texture_set_layout(renderer.textures),
	}
}

@(private = "file")
get_push_constant_ranges :: proc() -> [1]vk.PushConstantRange {
	return {
		vk.PushConstantRange {
			stageFlags = {.VERTEX, .FRAGMENT},
			offset = 0,
			size = size_of(Push_Constants_Data),
		},
	}
}

renderer_destroy :: proc(r: ^Renderer) {
	if r == nil {
		return
	}

	if r.device.logical != nil {
		_ = vk.DeviceWaitIdle(r.device.logical)
	}

	destroy_depth_texture(r)

	passes_destroy(&r.passes)
	pipelines_destroy(&r.pipelines, r.device)
	textures_destroy(&r.textures, r.device)
	materials_destroy(&r.materials, r.device)
	meshes_destroy(&r.meshes, r.device)
	shaders_destroy(&r.shaders, r.device)
	mipgen_queue_destroy(&r.mipgen_queue)
	upload_queue_destroy(&r.upload_queue, r.device)
	frame_ring_destroy(&r.frame_ring, r.device)
	surface_destroy(&r.surface, r.instance, r.device)
	device_destroy(&r.device)
	instance_destroy(&r.instance)
	virtual.arena_destroy(&r.arena)
	free(r)
}

@(require_results)
renderer_reserve_mesh :: proc(r: ^Renderer) -> Mesh_Handle {
	assert(r != nil)
	return meshes_reserve(&r.meshes)
}

@(require_results)
renderer_add_mesh :: proc(r: ^Renderer, mesh: Mesh) -> (Mesh_Handle, Mesh_Error) {
	assert(r != nil)
	return meshes_add(&r.meshes, &r.upload_queue, r.frame_ring, mesh)
}

renderer_replace_mesh :: proc(r: ^Renderer, handle: Mesh_Handle, mesh: Mesh) -> Mesh_Error {
	assert(r != nil)
	return meshes_replace(&r.meshes, &r.upload_queue, r.frame_ring, handle, mesh)
}

renderer_destroy_mesh :: proc(r: ^Renderer, handle: Mesh_Handle) {
	assert(r != nil)
	meshes_remove(&r.meshes, r.frame_ring, handle)
}

@(require_results)
renderer_reserve_texture :: proc(
	r: ^Renderer,
	fallback := Texture_Fallback.Color_Default,
) -> Texture_Handle {
	assert(r != nil)
	return textures_reserve(&r.textures, fallback)
}

// This function returns a valid handle even when there is an error
@(require_results)
renderer_add_texture :: proc(
	r: ^Renderer,
	image: Image,
	options := Texture_Options{},
	fallback := Texture_Fallback.Color_Error,
) -> (
	Texture_Handle,
	Texture_Error,
) {
	assert(r != nil)
	return textures_add(
		&r.textures,
		r.device,
		&r.mipgen_queue,
		&r.upload_queue,
		r.frame_ring,
		image,
		options,
		fallback,
	)
}

renderer_replace_texture :: proc(
	r: ^Renderer,
	handle: Texture_Handle,
	image: Image,
	options := Texture_Options{},
) -> Texture_Error {
	assert(r != nil)
	return textures_replace(
		&r.textures,
		r.device,
		&r.mipgen_queue,
		&r.upload_queue,
		r.frame_ring,
		handle,
		image,
		options,
	)
}

renderer_destroy_texture :: proc(r: ^Renderer, handle: Texture_Handle) {
	assert(r != nil)
	textures_remove(&r.textures, r.frame_ring, handle)
}

renderer_set_texture_sampler_options :: proc(r: ^Renderer, options: Texture_Sampler_Options) {
	assert(r != nil)
	textures_set_sampler_options(&r.textures, options)
}

renderer_add_material :: proc(
	r: ^Renderer,
	params: $P,
	props := Material_Properties{},
) -> (
	handle: Material_Handle,
	err: Material_Error,
) {
	assert(r != nil)
	handle = materials_add(&r.materials, params, props) or_return
	new_variants := materials_take_new_variants(&r.materials)
	for variant in new_variants {
		passes_add_variant(&r.passes, r.device, variant)
	}
	delete(new_variants)
	return handle, nil
}

renderer_replace_material :: proc(
	r: ^Renderer,
	handle: Material_Handle,
	params: $P,
	props := Material_Properties{},
) -> Material_Error {
	assert(r != nil)
	materials_replace(&r.materials, r.frame_ring, handle, params, props) or_return
	new_variants := materials_take_new_variants(&r.materials)
	for variant in new_variants {
		passes_add_variant(&r.passes, r.device, variant)
	}
	delete(new_variants)
	return nil
}

renderer_destroy_material :: proc(r: ^Renderer, handle: Material_Handle) {
	assert(r != nil)
	materials_remove(&r.materials, r.frame_ring, handle)
}

renderer_get_material :: proc(
	r: ^Renderer,
	handle: Material_Handle,
	$P: typeid,
) -> (
	P,
	Material_Error,
) {
	assert(r != nil)
	return materials_get(&r.materials, handle, P)
}

renderer_register_material_type :: proc(
	r: ^Renderer,
	$P, $D: typeid,
	name: string,
	resolve: proc(_: ^Textures, _: P) -> D,
) -> Material_Type_Id {
	assert(r != nil)
	return materials_register_type(&r.materials, P, D, name, resolve)
}

@(private = "file")
forward_select :: proc(
	shaders: ^Shaders,
	props: Material_Properties,
	base: Raster_State,
	type_name: string,
) -> Maybe(Pass_Selection) {
	vertex, vertex_ok := shaders_get_program(shaders, "Forward", "VSMain", .VERTEX)
	fragment, fragment_ok := shaders_get_program(shaders, "Forward", "FSMain", .FRAGMENT)
	if !vertex_ok || !fragment_ok {
		return nil
	}

	state := base
	state.cull_mode = .None if props.double_sided else .Back
	state.blend_mode = alpha_mode_to_blend_mode(props.alpha_mode)
	if alpha_mode_is_blended(props.alpha_mode) {
		state.depth_write = false
	}

	return {vertex = vertex, fragment = fragment, raster_state = state}
}

@(require_results)
renderer_draw :: proc(r: ^Renderer, scene: Scene) -> Renderer_Error {
	free_all(virtual.arena_allocator(&r.arena))
	context.temp_allocator = virtual.arena_allocator(&r.arena)

	textures_reconfigure_dirty_samplers(&r.textures, r.device) or_return
	updates := textures_take_updates(&r.textures, context.temp_allocator)
	materials_mark_dirty(&r.materials, updates[:])
	materials_update_dirty(&r.materials, &r.textures, r.device, r.frame_ring)

	frame_context := frame_begin(&r.frame_ring, r.device) or_return
	frame_data, ok := write_frame_data(r, frame_context, scene)
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

	upload_queue_record_commands(&r.upload_queue, frame_context.command_buffer)
	mipgen_queue_record_commands(&r.mipgen_queue, frame_context.command_buffer)
	record_commands(r, frame_context.command_buffer, frame_data, surface_texture)

	textures_destroy_pending(&r.textures, r.device, frame_context.finished_timeline_value)
	materials_destroy_pending(&r.materials, frame_context.finished_timeline_value)
	meshes_destroy_pending(&r.meshes, frame_context.finished_timeline_value)
	upload_queue_retire(&r.upload_queue, frame_context.finished_timeline_value)
	upload_queue_flush(&r.upload_queue, r.device) or_return
	frame_submit(&r.frame_ring, r.device, frame_context, surface_texture.presentable) or_return

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
		pipelines_set_target(
			&r.pipelines,
			r.device,
			r.frame_ring,
			r.shaders,
			r.forward_target,
			Attachment_Formats{color = {r.surface.format}, depth = .D32_SFLOAT, samples = ._1},
		) or_return
	}

	create_depth_texture(r) or_return
	return nil
}

@(require_results)
write_frame_data :: proc(
	renderer: ^Renderer,
	frame: Frame_Context,
	scene: Scene,
) -> (
	data: Frame_Data,
	ok: bool,
) {
	width := int(renderer.surface.extent.width)
	height := int(renderer.surface.extent.height)
	view := View_Data {
		world_to_clip = get_world_to_clip_matrix(scene.camera, width, height),
		position      = scene.camera.transform.translation,
	}
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
			radius   = point_light.radius,
			power    = point_light.power,
			color    = point_light.color,
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
			direction   = dir_light.direction,
			illuminance = dir_light.illuminance,
			color       = dir_light.color,
		}
	}

	lighting := Lighting_Data {
		ambient_color        = scene.ambient_light.color,
		ambient_illuminance  = scene.ambient_light.illuminance,
		point_lights_address = point_lights.address,
		point_light_count    = u32(len(point_lights.data)),
		dir_lights_address   = dir_lights.address,
		dir_light_count      = u32(len(dir_lights.data)),
	}
	data.lighting = scratch_new_clone(frame.scratch, lighting) or_return

	scratch_objects := make([dynamic]Object_Id, 0, len(scene.mesh_objects), context.temp_allocator)
	for mesh_object, index in scene.mesh_objects {
		if meshes_is_loaded(&renderer.meshes, mesh_object.mesh) {
			material_info, has_material := materials_get_info(
				&renderer.materials,
				mesh_object.material,
			)
			if !has_material {
				continue
			}

			pipeline, has_pipeline := passes_get_pipeline(
				renderer.passes,
				renderer.forward_pass,
				material_info.variant,
			).?
			if !has_pipeline {
				continue
			}

			indexed := meshes_is_indexed(&renderer.meshes, mesh_object.mesh)
			draw_key := make_draw_key(pipeline, indexed, mesh_object.mesh)
			append(
				&scratch_objects,
				{
					draw_key = draw_key,
					pipeline = pipeline,
					mesh_handle = mesh_object.mesh,
					object_index = index,
				},
			)
		}
	}

	sort.quick_sort_proc(scratch_objects[:], proc(a, b: Object_Id) -> int {
		switch {
		case a.draw_key > b.draw_key:
			return 1
		case a.draw_key < b.draw_key:
			return -1
		case:
			return 0
		}
	})

	batches := make([dynamic]Draw_Batch, context.temp_allocator)
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
		mesh_info, mesh_ok := meshes_get_info(
			&renderer.meshes,
			scratch_objects[draw_start].mesh_handle,
		)
		assert(mesh_ok)

		object := scratch_objects[draw_start]
		indexed := mesh_info.index_count > 0
		command_index := u32(len(indexed_commands) if indexed else len(non_indexed_commands))

		draw := Draw_Data {
			mesh_record_address = mesh_info.record_address,
			instance_offset     = u32(draw_start),
		}
		if mesh_info.index_count > 0 {
			append(&indexed_draws, draw)
			append(
				&indexed_commands,
				{
					firstIndex = mesh_info.first_index,
					indexCount = mesh_info.index_count,
					instanceCount = u32(instance_count),
					vertexOffset = 0,
					firstInstance = 0,
				},
			)
		} else {
			append(&non_indexed_draws, draw)
			append(
				&non_indexed_commands,
				{
					vertexCount = mesh_info.vertex_count,
					instanceCount = u32(instance_count),
					firstVertex = 0,
					firstInstance = 0,
				},
			)
		}

		last := len(batches) - 1
		if last < 0 ||
		   batches[last].pipeline != object.pipeline ||
		   batches[last].indexed != indexed {
			append(
				&batches,
				{
					pipeline = object.pipeline,
					indexed = indexed,
					first_command = command_index,
					command_count = 0,
				},
			)
			last += 1
		}
		batches[last].command_count += 1
	}
	data.indexed_draws = scratch_slice_clone(frame.scratch, indexed_draws[:]) or_return
	data.non_indexed_draws = scratch_slice_clone(frame.scratch, non_indexed_draws[:]) or_return
	data.indexed_commands = scratch_slice_clone(frame.scratch, indexed_commands[:]) or_return
	data.non_indexed_commands = scratch_slice_clone(
		frame.scratch,
		non_indexed_commands[:],
	) or_return
	data.batches = batches[:]

	data.instances = scratch_make(frame.scratch, []Instance_Data, len(scratch_objects)) or_return
	for scratch_object, i in scratch_objects {
		object := scene.mesh_objects[scratch_object.object_index]
		material, _ := materials_get_info(&renderer.materials, object.material)
		data.instances.data[i] = Instance_Data {
			object_to_world  = affine_to_matrix3x4(object.transform),
			material_type    = material.type,
			material_address = material.address,
		}
	}

	data.clear_color = scene.clear_color
	return data, true
}

record_commands :: proc(
	renderer: ^Renderer,
	commands: vk.CommandBuffer,
	frame_data: Frame_Data,
	surface: Surface_Texture,
) {
	subresource_range := vk.ImageSubresourceRange {
		aspectMask     = {.COLOR},
		baseMipLevel   = 0,
		levelCount     = 1,
		baseArrayLayer = 0,
		layerCount     = 1,
	}

	record_image_barrier(
		commands,
		{
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
		},
	)
	record_image_barrier(
		commands,
		{
			image = surface.texture.handle,
			srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
			srcAccessMask = {},
			dstStageMask = {.COLOR_ATTACHMENT_OUTPUT},
			dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
			oldLayout = .UNDEFINED,
			newLayout = .COLOR_ATTACHMENT_OPTIMAL,
			subresourceRange = subresource_range,
		},
	)
	record_draw_commands(renderer, commands, frame_data, surface)
	record_image_barrier(
		commands,
		{
			image = surface.texture.handle,
			srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
			srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
			dstStageMask = {},
			dstAccessMask = {},
			oldLayout = .COLOR_ATTACHMENT_OPTIMAL,
			newLayout = .PRESENT_SRC_KHR,
			subresourceRange = subresource_range,
		},
	)
}

record_draw_commands :: proc(
	renderer: ^Renderer,
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
		clearValue = {depthStencil = {depth = 0.0}},
	}
	render_info := vk.RenderingInfo {
		sType = .RENDERING_INFO,
		renderArea = {offset = {0, 0}, extent = renderer.surface.extent},
		layerCount = 1,
		colorAttachmentCount = 1,
		pColorAttachments = &color_attachment_info,
		pDepthAttachment = &depth_attachment_info,
	}

	vk.CmdBeginRendering(commands, &render_info)

	viewport := vk.Viewport {
		x        = 0.0,
		y        = 0.0,
		width    = f32(renderer.surface.extent.width),
		height   = f32(renderer.surface.extent.height),
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
		view_address      = frame_data.view.address,
		lighting_address  = frame_data.lighting.address,
		instances_address = frame_data.instances.address,
	}

	descriptor_sets := []vk.DescriptorSet {
		textures_get_sampler_set(renderer.textures),
		textures_get_texture_set(renderer.textures),
	}
	vk.CmdBindDescriptorSets(
		commands,
		.GRAPHICS,
		renderer.pipelines.layout,
		0,
		u32(len(descriptor_sets)),
		raw_data(descriptor_sets),
		0,
		nil,
	)

	vk.CmdBindIndexBuffer(commands, meshes_get_index_buffer(renderer.meshes).handle, 0, .UINT32)

	bound := Graphics_Pipeline_Id(max(u32))
	for batch in frame_data.batches {
		if batch.pipeline != bound {
			vk.CmdBindPipeline(
				commands,
				.GRAPHICS,
				pipelines_get_handle(&renderer.pipelines, batch.pipeline),
			)
			bound = batch.pipeline
		}

		draws := frame_data.indexed_draws if batch.indexed else frame_data.non_indexed_draws
		constants.draws_address =
			draws.address + Device_Address(batch.first_command) * size_of(Draw_Data)
		vk.CmdPushConstants(
			commands,
			renderer.pipelines.layout,
			{.VERTEX, .FRAGMENT},
			0,
			size_of(constants),
			&constants,
		)

		if batch.indexed {
			stride := Device_Size(size_of(vk.DrawIndexedIndirectCommand))
			vk.CmdDrawIndexedIndirect(
				commands,
				frame_data.indexed_commands.buffer_handle,
				frame_data.indexed_commands.offset + Device_Size(batch.first_command) * stride,
				batch.command_count,
				u32(stride),
			)
		} else {
			stride := Device_Size(size_of(vk.DrawIndirectCommand))
			vk.CmdDrawIndirect(
				commands,
				frame_data.non_indexed_commands.buffer_handle,
				frame_data.non_indexed_commands.offset + Device_Size(batch.first_command) * stride,
				batch.command_count,
				u32(stride),
			)
		}
	}

	vk.CmdEndRendering(commands)
}

record_image_barrier :: proc(cmd: vk.CommandBuffer, barrier: vk.ImageMemoryBarrier2) {
	image_barrier := barrier
	image_barrier.sType = .IMAGE_MEMORY_BARRIER_2
	dependency_info := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &image_barrier,
	}
	vk.CmdPipelineBarrier2(cmd, &dependency_info)
}

@(require_results)
create_depth_texture :: proc(r: ^Renderer) -> Texture_Error {
	texture_destroy(&r.depth_texture, r.device)

	depth_extent := vk.Extent3D{r.surface.extent.width, r.surface.extent.height, 1}

	texture_init(
		&r.depth_texture,
		r.device,
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
