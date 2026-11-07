package main
import "core:container/queue"
import "core:slice"
import vk "vendor:vulkan"

Upload_Queue :: struct {
	staging: Staging_Buffer,
	pending: queue.Queue(Upload),	
}

Resource_Usage :: struct {
	stages: vk.PipelineStageFlags2,
	access: vk.AccessFlags2,
	layout: vk.ImageLayout,
}

@(private="file")
Texture_Upload :: struct {
	texture: Texture,
	usage: Resource_Usage,
	staging: Staging_Subbuffer(u8),
	layer: u32,
}

@(private="file")
Buffer_Upload :: struct {
	buffer: vk.Buffer,
	usage: Resource_Usage,
	staging: Staging_Subbuffer(u8),
	offset: Device_Size,
}

@(private="file")
Upload :: union {
	Buffer_Upload,
	Texture_Upload,
}

@(require_results)
upload_queue_init :: proc(
	u: ^Upload_Queue, 
	device: Device, 
	staging_capacity: Device_Size,
) -> (err: Buffer_Error) {
	assert(u != nil)

	defer if err != nil {
		upload_queue_destroy(u, device)	
	}
	
	staging_init(&u.staging, device, staging_capacity) or_return
	queue.init(&u.pending)
	return
}

upload_queue_destroy :: proc(u: ^Upload_Queue, device: Device) {
	if u == nil {
		return
	}

	queue.destroy(&u.pending)
	staging_destroy(&u.staging, device)
	u^ = {}
}

upload_queue_retire :: proc(u: ^Upload_Queue, frame: Frame_Context) {
	assert(u != nil)
	staging_retire(&u.staging, frame.finished_timeline_value)
}

@(require_results)
upload_queue_flush :: proc(u: ^Upload_Queue, device: Device) -> (err: Buffer_Error) {
	assert(u != nil)
	staging_flush(&u.staging, device) or_return
	return
}

@(require_results)
upload_buffer_reserve :: proc(
	uqueue: ^Upload_Queue,
	frame_ring: Frame_Ring,
	buffer: Buffer, 
	size: Maybe(int) = nil,
	usage: Maybe(Resource_Usage) = nil,
	offset: Device_Size = 0,
) -> (bytes: []byte, ok: bool) {
	assert(uqueue != nil)

	assert(buffer.size >= offset)
	staging_size: Device_Size
	if size == nil {
		staging_size = buffer.size - offset
	} else {
		staging_size = Device_Size(size.?)
	}

	assert(.TRANSFER_DST in buffer.usage)
	assert(buffer.size >= offset + staging_size)
	if staging_size == 0 {
		return nil, true
	}

	buffer_usage: Resource_Usage
	if usage == nil {
		buffer_usage = resource_usage_from_buffer_usage(buffer.usage)
	} else {
		buffer_usage = usage.?
	}

	staging := staging_make(&uqueue.staging, frame_ring, []u8, staging_size) or_return

	queue.enqueue(&uqueue.pending, Buffer_Upload {
		buffer = buffer.handle,
		usage = buffer_usage,
		offset = offset,
		staging = staging,
	})

	return staging.data, true
}

@(require_results)
upload_buffer :: proc(
	uqueue: ^Upload_Queue, 
	frame_ring: Frame_Ring,
	buffer: Buffer, 
	bytes: []byte,
	usage: Maybe(Resource_Usage) = nil,
	offset: Device_Size = 0,
) -> (ok: bool) {
	staging := upload_buffer_reserve(
		uqueue, frame_ring, 
		buffer, len(bytes), 
		usage, offset,
	) or_return

	copy(staging, bytes)

	return true	
}

@(require_results)
upload_subbuffer_reserve :: proc(
	uqueue: ^Upload_Queue, 
	frame_ring: Frame_Ring,
	buffer: Pool_Subbuffer($T), 
	count: Maybe(int) = nil,
	usage: Maybe(Resource_Usage) = nil,
	offset: Device_Size = 0,
) -> (values: []T, ok: bool) {
	assert(uqueue != nil)

	assert(buffer.size >= offset)
	staging_size: Device_Size
	if count == nil {
		staging_size = buffer.size - offset
	} else {
		staging_size = Device_Size(count.? * size_of(T))
	}

	assert(.TRANSFER_DST in buffer.buffer_usage)
	assert(buffer.size >= offset + staging_size)
	if staging_size == 0 {
		return nil, true
	}

	buffer_usage: Resource_Usage
	if usage == nil {
		buffer_usage = resource_usage_from_buffer_usage(buffer.buffer_usage)
	} else {
		buffer_usage = usage.?
	}

	staging := staging_make(&uqueue.staging, frame_ring, []u8, staging_size) or_return

	queue.enqueue(&uqueue.pending, Buffer_Upload {
		buffer = buffer.buffer_handle,
		offset = buffer.offset + offset,
		usage = buffer_usage,
		staging = staging,
	})

	return slice.reinterpret([]T, staging.data), true
}

@(require_results)
upload_subbuffer :: proc(
	uqueue: ^Upload_Queue, 
	frame_ring: Frame_Ring,
	buffer: Pool_Subbuffer($T), 
	values: []T,
	usage: Maybe(Resource_Usage) = nil,
	offset: Device_Size = 0,
) -> (ok: bool) {
	staging := upload_subbuffer_reserve(
		uqueue, frame_ring, 
		buffer, len(values), 
		usage, offset,
	) or_return

	copy(staging, values)

	return true	
}

@(require_results)
upload_texture :: proc(
	uqueue: ^Upload_Queue, 
	frame_ring: Frame_Ring,
	texture: Texture, 
	image: Image,
	usage: Maybe(Resource_Usage) = nil,
	layer: int = 0,
) -> (ok: bool) {
	assert(uqueue != nil)

	assert(image_is_valid(image))
	assert(image_format_matches_vk(image.format, texture.format))

	assert(texture.extent.depth == 1)
	assert(texture.extent.width == u32(image.width))
	assert(texture.extent.height == u32(image.height))
	assert(layer >= 0 && layer < int(texture.array_layers))
	assert(.TRANSFER_DST in texture.usage)
	
	texture_usage: Resource_Usage
	if usage == nil {
		texture_usage = resource_usage_from_texture_usage(texture.usage)
	} else {
		texture_usage = usage.?
	}

	staging := staging_slice_clone(&uqueue.staging, frame_ring, image.bytes) or_return
	queue.enqueue(&uqueue.pending, Texture_Upload{
		texture = texture,
		usage = texture_usage,
		staging = staging,
		layer = u32(layer),
	})

	return true	
}

ALL_SHADER_STAGES :: vk.PipelineStageFlags2 {
	.PRE_RASTERIZATION_SHADERS,
	.FRAGMENT_SHADER,
	.COMPUTE_SHADER,
}

resource_usage_from_buffer_usage :: proc(usage: vk.BufferUsageFlags) -> (r: Resource_Usage) {
	if .VERTEX_BUFFER in usage {
		r.stages += {.VERTEX_ATTRIBUTE_INPUT}
		r.access += {.VERTEX_ATTRIBUTE_READ}
	}
	if .INDEX_BUFFER in usage {
		r.stages += {.INDEX_INPUT}
		r.access += {.INDEX_READ}
	}
	if .INDIRECT_BUFFER in usage {
		r.stages += {.DRAW_INDIRECT}
		r.access += {.INDIRECT_COMMAND_READ}
	}
	if .UNIFORM_BUFFER in usage {
		r.stages += ALL_SHADER_STAGES
		r.access += {.UNIFORM_READ}
	}
	if .UNIFORM_TEXEL_BUFFER in usage {
		r.stages += ALL_SHADER_STAGES
		r.access += {.SHADER_SAMPLED_READ}
	}
	if usage & {.STORAGE_BUFFER, .STORAGE_TEXEL_BUFFER, .SHADER_DEVICE_ADDRESS} != {} {
		r.stages += ALL_SHADER_STAGES
		r.access += {.SHADER_STORAGE_READ}
	}
	if .TRANSFER_SRC in usage {
		r.stages += {.COPY}
		r.access += {.TRANSFER_READ}
	}
	if .TRANSFER_DST in usage {
		r.stages += {.COPY}
		r.access += {.TRANSFER_WRITE}
	}
	r.layout = .UNDEFINED
	return
}

resource_usage_from_texture_usage :: proc(usage: vk.ImageUsageFlags) -> (r: Resource_Usage) {
	if .SAMPLED in usage {
		r.stages += ALL_SHADER_STAGES
		r.access += {.SHADER_SAMPLED_READ}
	}
	if .STORAGE in usage {
		r.stages += ALL_SHADER_STAGES
		r.access += {.SHADER_STORAGE_READ, .SHADER_STORAGE_WRITE}
	}
	if .TRANSFER_SRC in usage {
		r.stages += {.COPY, .BLIT}
		r.access += {.TRANSFER_READ}
	}

	switch {
	case .STORAGE in usage:      r.layout = .GENERAL
	case .SAMPLED in usage:      r.layout = .SHADER_READ_ONLY_OPTIMAL
	case .TRANSFER_SRC in usage: r.layout = .TRANSFER_SRC_OPTIMAL
	case:                        r.layout = .GENERAL
	}
	return
}

upload_queue_record_commands :: proc(u: ^Upload_Queue, commands: vk.CommandBuffer) {
	pre_barriers := make([dynamic]vk.ImageMemoryBarrier2, context.temp_allocator)
	for i in 0..<queue.len(u.pending) {
		switch upload in queue.get(&u.pending, i) {
		case Buffer_Upload:
			// No pre-barriers for buffers
		case Texture_Upload:
			get_texture_pre_barrier(&pre_barriers, upload)
		}
	}

	if len(pre_barriers) > 0 {
		vk.CmdPipelineBarrier2(commands, &vk.DependencyInfo {
			sType = .DEPENDENCY_INFO,
			imageMemoryBarrierCount = u32(len(pre_barriers)),
			pImageMemoryBarriers = raw_data(pre_barriers),
		})
	}

	image_barriers := make([dynamic]vk.ImageMemoryBarrier2, context.temp_allocator)
	buffer_barriers := make([dynamic]vk.BufferMemoryBarrier2, context.temp_allocator)
	for queue.len(u.pending) > 0 {
		switch upload in queue.dequeue(&u.pending) {
		case Buffer_Upload:
			record_buffer_upload(commands, &buffer_barriers, upload)
		case Texture_Upload:
			record_texture_upload(commands, &image_barriers, upload)
		}
	}

	if len(image_barriers) > 0 || len(buffer_barriers) > 0 {
		vk.CmdPipelineBarrier2(commands, &vk.DependencyInfo {
			sType = .DEPENDENCY_INFO,
			imageMemoryBarrierCount = u32(len(image_barriers)),
			pImageMemoryBarriers = raw_data(image_barriers),
			bufferMemoryBarrierCount = u32(len(buffer_barriers)),
			pBufferMemoryBarriers = raw_data(buffer_barriers),
		})
	}
}

@(private="file")
get_texture_pre_barrier :: proc(
	barriers: ^[dynamic]vk.ImageMemoryBarrier2, 
	upload: Texture_Upload,
) {
	append(barriers, {
		sType = .IMAGE_MEMORY_BARRIER_2,
		image = upload.texture.handle,
		srcStageMask = upload.usage.stages,
		srcAccessMask = {},
		dstStageMask = {.TRANSFER},
		dstAccessMask = {.TRANSFER_WRITE},
		oldLayout = .UNDEFINED,
		newLayout = .TRANSFER_DST_OPTIMAL,
		subresourceRange = {
			aspectMask = upload.texture.full_view.aspect_mask,
			baseArrayLayer = upload.layer,
			layerCount = 1,
			baseMipLevel = 0,
			levelCount = 1,
		},
	})
}

@(private="file")
record_buffer_upload :: proc(
	commands: vk.CommandBuffer, 
	barriers: ^[dynamic]vk.BufferMemoryBarrier2,
	upload: Buffer_Upload,
) {
	buffer_copy := vk.BufferCopy {
		srcOffset = upload.staging.offset,
		dstOffset = upload.offset,
		size = staging_subbuffer_size(upload.staging),
	}

	vk.CmdCopyBuffer(
		commands,
		upload.staging.buffer_handle,
		upload.buffer,
		1, &buffer_copy,
	)

	append(barriers, {
		sType = .BUFFER_MEMORY_BARRIER_2,
		srcStageMask = {.TRANSFER},
		srcAccessMask = {.TRANSFER_WRITE},
		dstStageMask = upload.usage.stages,
		dstAccessMask = upload.usage.access,
		buffer = upload.buffer,
		offset = upload.offset,
		size = staging_subbuffer_size(upload.staging),
	})
}

@(private="file")
record_texture_upload :: proc(
	commands: vk.CommandBuffer, 
	barriers: ^[dynamic]vk.ImageMemoryBarrier2,
	upload: Texture_Upload,
) {
	image_copy := vk.BufferImageCopy {
		imageExtent = upload.texture.extent,
		bufferOffset = upload.staging.offset,
		imageSubresource = {
			aspectMask = upload.texture.full_view.aspect_mask,
			baseArrayLayer = upload.layer,
			layerCount = 1,
			mipLevel = 0,
		},
	}
	vk.CmdCopyBufferToImage(
		commands, 
		upload.staging.buffer_handle, 
		upload.texture.handle, 
		.TRANSFER_DST_OPTIMAL,
		1, &image_copy,
	)

	append(barriers, {
		sType = .IMAGE_MEMORY_BARRIER_2,
		image = upload.texture.handle,
		srcStageMask = {.TRANSFER},
		srcAccessMask = {.TRANSFER_WRITE},
		dstStageMask = upload.usage.stages,
		dstAccessMask = upload.usage.access,
		oldLayout = .TRANSFER_DST_OPTIMAL,
		newLayout = upload.usage.layout,
		subresourceRange = {
			aspectMask = upload.texture.full_view.aspect_mask,
			baseArrayLayer = upload.layer,
			layerCount = 1,
			baseMipLevel = 0,
			levelCount = 1,
		},
	})
}
