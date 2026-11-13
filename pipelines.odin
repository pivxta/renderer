package main
import vk "vendor:vulkan"
import "core:container/queue"

Graphics_Pipeline_Id :: distinct u32

Graphics_Target_Id :: distinct u32

Cull_Mode :: enum {
	None,
	Back,
	Front,
}

Depth_Test :: enum {
	Off,
	Closer_Or_Equal,
	Equal,
	Farther,
}

Blend_Mode :: enum {
	Opaque,
	Alpha,
	Premultiplied,
	Additive,
	Multiply,
}

Attachment_Formats :: struct {
	color:   [dynamic; 8]vk.Format,
	depth:   vk.Format,
	stencil: vk.Format,
	samples: vk.SampleCountFlag,
}

Raster_State :: struct {
	cull_mode:   Cull_Mode,
	blend_mode:  Blend_Mode,
	depth_test:  Depth_Test,
	depth_write: bool,
	depth_bias:  bool,
}

Pipelines :: struct {
	layout:           vk.PipelineLayout,
	cache:            vk.PipelineCache,
	targets:          [dynamic]Attachment_Formats,
	graphics:         [dynamic]Graphics_Pipeline_Entry,
	graphics_by_key:  map[Graphics_Pipeline_Key]Graphics_Pipeline_Id,
	pending_frees:    queue.Queue(Pending_Free),
}

Graphics_Pipeline_Key :: struct {
	target:       Graphics_Target_Id,
	vertex:       Shader_Program_Id,
	fragment:     Maybe(Shader_Program_Id),
	raster_state: Raster_State,
}

@(private="file")
Graphics_Pipeline_Entry :: struct {
	key:    Graphics_Pipeline_Key,
	handle: vk.Pipeline,
}

@(private="file")
Pending_Free :: struct {
	retire_value: u64,
	pipeline:     vk.Pipeline,
}

@(require_results)
pipelines_init :: proc(
	pipelines: ^Pipelines, 
	device: Device, 
	set_layouts: []vk.DescriptorSetLayout,
	push_constant_ranges: []vk.PushConstantRange,
	allocator := context.allocator,
) -> (result: vk.Result) {
	assert(pipelines != nil)

	defer if result != .SUCCESS {
		pipelines_destroy(pipelines, device)
	}

	layout_info := vk.PipelineLayoutCreateInfo {
		sType = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount = u32(len(set_layouts)),
		pSetLayouts = raw_data(set_layouts),
		pushConstantRangeCount = u32(len(push_constant_ranges)),
		pPushConstantRanges = raw_data(push_constant_ranges),
	}
	vk.CreatePipelineLayout(device.logical, &layout_info, nil, &pipelines.layout) or_return

	// TODO: Load the pipeline cache from a file
	cache_info := vk.PipelineCacheCreateInfo {
		sType = .PIPELINE_CACHE_CREATE_INFO,
		initialDataSize = 0,
		pInitialData    = nil,
	}
	vk.CreatePipelineCache(device.logical, &cache_info, nil, &pipelines.cache) or_return

	pipelines.targets = make([dynamic]Attachment_Formats, allocator)
	pipelines.graphics = make([dynamic]Graphics_Pipeline_Entry, allocator)
	pipelines.graphics_by_key = make(map[Graphics_Pipeline_Key]Graphics_Pipeline_Id, allocator)
	queue.init(&pipelines.pending_frees, queue.DEFAULT_CAPACITY, allocator)

	return .SUCCESS
}

pipelines_destroy :: proc(pipelines: ^Pipelines, device: Device) {
	if pipelines == nil {
		return
	}

	pipelines_destroy_pending(pipelines, device, max(u64))

	for entry in pipelines.graphics {
		if entry.handle != 0 {
			vk.DestroyPipeline(device.logical, entry.handle, nil)
		}
	}

	delete(pipelines.targets)
	delete(pipelines.graphics)
	delete(pipelines.graphics_by_key)
	queue.destroy(&pipelines.pending_frees)

	if pipelines.cache != 0 {
		vk.DestroyPipelineCache(device.logical, pipelines.cache, nil)
	}

	if pipelines.layout != 0 {
		vk.DestroyPipelineLayout(device.logical, pipelines.layout, nil)
	}
}

pipelines_get_or_add :: pipelines_get_or_add_graphics

pipelines_get_handle :: pipelines_get_graphics_handle

@(require_results)
pipelines_get_or_add_graphics :: proc(
	pipelines: ^Pipelines,
	device: Device,
	shaders: Shaders,
	key: Graphics_Pipeline_Key,
) -> (id: Graphics_Pipeline_Id, err: vk.Result) {
	assert(pipelines != nil)
	if pipeline_id, exists := pipelines.graphics_by_key[key]; exists {
		return pipeline_id, .SUCCESS
	}
	
	pipeline := create_graphics_pipeline(pipelines, device, shaders, key) or_return
	pipeline_id := Graphics_Pipeline_Id(len(pipelines.graphics))
	append(&pipelines.graphics, {
		handle = pipeline,
		key = key,
	})
	pipelines.graphics_by_key[key] = pipeline_id
	return pipeline_id, .SUCCESS
}

@(require_results)
pipelines_get_graphics_handle :: proc(
	pipelines: ^Pipelines, 
	id: Graphics_Pipeline_Id,
) -> vk.Pipeline {
	assert(pipelines != nil)
	assert(int(id) < len(pipelines.graphics))
	return pipelines.graphics[id].handle
}

@(require_results)
pipelines_add_target :: proc(
	pipelines: ^Pipelines, 
	formats: Attachment_Formats,
) -> Graphics_Target_Id {
	assert(pipelines != nil)
	target_id := Graphics_Target_Id(len(pipelines.targets))
	append(&pipelines.targets, formats)
	return target_id
}

@(require_results)
pipelines_set_target :: proc(
	pipelines: ^Pipelines, 
	device: Device,
	frame_ring: Frame_Ring,
	shaders: Shaders,
	target: Graphics_Target_Id,
	formats: Attachment_Formats,
) -> vk.Result {
	assert(pipelines != nil)
	pipelines.targets[target] = formats
	for &pipeline in pipelines.graphics {
		if pipeline.key.target == target {
			new_pipeline := create_graphics_pipeline(pipelines, device, shaders, pipeline.key) or_return
			defer_free(pipelines, frame_ring, pipeline.handle)
			pipeline.handle = new_pipeline
		}
	}
	return .SUCCESS
}

@(private="file")
defer_free :: proc(pipelines: ^Pipelines, frame_ring: Frame_Ring, pipeline: vk.Pipeline) {
	queue.enqueue(&pipelines.pending_frees, {
		retire_value = frame_ring.timeline_value + 1,
		pipeline = pipeline,
	})
}

pipelines_destroy_pending :: proc(pipelines: ^Pipelines, device: Device, finished_value: u64) {
	assert(pipelines != nil)

	for queue.len(pipelines.pending_frees) > 0 {
		pending_free := queue.front_ptr(&pipelines.pending_frees)
		if pending_free.retire_value <= finished_value {
			vk.DestroyPipeline(device.logical, pending_free.pipeline, nil)
			queue.dequeue(&pipelines.pending_frees)
		} else {
			break	
		}
	}
}

@(private="file", require_results)
create_graphics_pipeline :: proc(
	pipelines: ^Pipelines, 
	device: Device,
	shaders: Shaders, 
	key: Graphics_Pipeline_Key,
) -> (pipeline: vk.Pipeline, result: vk.Result) {
	shader_stages := [dynamic; 2]vk.PipelineShaderStageCreateInfo {}
	append(&shader_stages, shaders_get_stage_info(shaders, key.vertex))
	if fragment, ok := key.fragment.?; ok {
		append(&shader_stages, shaders_get_stage_info(shaders, fragment))
	}

	vertex_state := vk.PipelineVertexInputStateCreateInfo {
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
	}

	input_assembly_state := vk.PipelineInputAssemblyStateCreateInfo {
		sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_LIST,
	}

	viewport_state := vk.PipelineViewportStateCreateInfo {
		sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount = 1,
	}

	raster_state := vk.PipelineRasterizationStateCreateInfo {
		sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = .FILL,
		lineWidth = 1,
		cullMode = cull_mode_to_vk(key.raster_state.cull_mode),
		frontFace = .COUNTER_CLOCKWISE,
		depthBiasEnable = b32(key.raster_state.depth_bias),
	}

	assert(int(key.target) < len(pipelines.targets))
	formats := pipelines.targets[key.target]
	enable_depth, compare := depth_test_to_vk(key.raster_state.depth_test)
	depth_stencil_state := vk.PipelineDepthStencilStateCreateInfo {
		sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		depthTestEnable = enable_depth && formats.depth != .UNDEFINED,
		depthWriteEnable = b32(key.raster_state.depth_write),
		depthCompareOp = compare,
	}

	blend_attachments: [8]vk.PipelineColorBlendAttachmentState
	for i in 0..<len(formats.color) {
		blend_attachments[i] = blend_mode_to_vk(key.raster_state.blend_mode if i == 0 else .Opaque)
	}
	blend_state := vk.PipelineColorBlendStateCreateInfo {
		sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = u32(len(formats.color)),
		pAttachments = &blend_attachments[0],
	}

	ms_state := vk.PipelineMultisampleStateCreateInfo {
		sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {formats.samples},
	}

	dynamic_states := []vk.DynamicState {.VIEWPORT, .SCISSOR, .DEPTH_BIAS}
	dynamic_state := vk.PipelineDynamicStateCreateInfo {
		sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = u32(len(dynamic_states)),
		pDynamicStates = raw_data(dynamic_states),
	}

	rendering_info := vk.PipelineRenderingCreateInfo {
		sType = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount = u32(len(formats.color)),
		pColorAttachmentFormats = raw_data(formats.color[:]),
		depthAttachmentFormat = formats.depth,
		stencilAttachmentFormat = formats.stencil,
	}

	pipeline_info := vk.GraphicsPipelineCreateInfo {
		sType = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext = rawptr(&rendering_info),
		layout = pipelines.layout,
		stageCount = u32(len(shader_stages)),
		pStages = raw_data(shader_stages[:]),
		pVertexInputState = &vertex_state,
		pInputAssemblyState = &input_assembly_state,
		pRasterizationState = &raster_state,
		pDepthStencilState = &depth_stencil_state,
		pViewportState = &viewport_state,
		pMultisampleState = &ms_state,
		pColorBlendState = &blend_state,
		pDynamicState = &dynamic_state,
	}

	vk.CreateGraphicsPipelines(
		device.logical, pipelines.cache, 
		1, &pipeline_info, 
		nil, &pipeline,
	) or_return

	return pipeline, .SUCCESS
}

@(private="file")
cull_mode_to_vk :: proc(m: Cull_Mode) -> vk.CullModeFlags {
	switch m {
	case .None:  return {}
	case .Back:  return {.BACK}
	case .Front: return {.FRONT}
	}
	return {}
}

@(private="file")
depth_test_to_vk :: proc(t: Depth_Test) -> (enable: b32, op: vk.CompareOp) {
	switch t {
	case .Off:             return false, .ALWAYS
	case .Closer_Or_Equal: return true, .GREATER_OR_EQUAL
	case .Equal:           return true, .EQUAL
	case .Farther:         return true, .LESS
	}
	return false, .ALWAYS
}

@(private="file")
blend_mode_to_vk :: proc(m: Blend_Mode) -> vk.PipelineColorBlendAttachmentState {
	s := vk.PipelineColorBlendAttachmentState {
		colorWriteMask = {.R, .G, .B, .A},
		colorBlendOp = .ADD,
		alphaBlendOp = .ADD,
	}
	switch m {
	case .Opaque:
		s.blendEnable = false
	case .Alpha:
		s.blendEnable = true
		s.srcColorBlendFactor, s.dstColorBlendFactor = .SRC_ALPHA, .ONE_MINUS_SRC_ALPHA
		s.srcAlphaBlendFactor, s.dstAlphaBlendFactor = .ONE, .ONE_MINUS_SRC_ALPHA
	case .Premultiplied:
		s.blendEnable = true
		s.srcColorBlendFactor, s.dstColorBlendFactor = .ONE, .ONE_MINUS_SRC_ALPHA
		s.srcAlphaBlendFactor, s.dstAlphaBlendFactor = .ONE, .ONE_MINUS_SRC_ALPHA
	case .Additive:
		s.blendEnable = true
		s.srcColorBlendFactor, s.dstColorBlendFactor = .ONE, .ONE
		s.srcAlphaBlendFactor, s.dstAlphaBlendFactor = .ZERO, .ONE
	case .Multiply:
		s.blendEnable = true
		s.srcColorBlendFactor, s.dstColorBlendFactor = .DST_COLOR, .ZERO
		s.srcAlphaBlendFactor, s.dstAlphaBlendFactor = .ZERO, .ONE
	}
	return s
}
