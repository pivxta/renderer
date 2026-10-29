package main
import "core:container/queue"
import "core:slice"
import vk "vendor:vulkan"

Upload_Queue :: struct {
	staging: Staging_Allocator,
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
	staging: Staging_Slice(u8),
	layer: u32,
}

@(private="file")
Buffer_Upload :: struct {
	buffer: Buffer,
	usage: Resource_Usage,
	staging: Staging_Slice(u8),
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
upload_buffer :: proc(
	u: ^Upload_Queue, 
	frame_ring: Frame_Ring,
	buffer: Buffer, 
	bytes: []byte,
	usage: Resource_Usage,
	offset: Device_Size = 0,
) -> (ok: bool) {
	assert(u != nil)
	assert(buffer.size >= offset + Device_Size(slice.size(bytes)))

	queue.enqueue(&u.pending, Buffer_Upload {
		buffer = buffer,
		usage = usage,
		offset = offset,
		staging = staging_slice_clone(&u.staging, frame_ring, bytes) or_return,
	})

	return true	
}

@(require_results)
upload_texture :: proc(
	u: ^Upload_Queue, 
	frame_ring: Frame_Ring,
	texture: Texture, 
	image: Image,
	usage: Resource_Usage,
	layer: int = 0,
) -> (ok: bool) {
	assert(u != nil)
	assert(image_is_valid(image))
	assert(texture.extent.depth == 1)
	assert(texture.extent.width == u32(image.width))
	assert(texture.extent.height == u32(image.height))
	assert(layer >= 0 && layer < int(texture.array_layers))

	staging := staging_slice_clone(&u.staging, frame_ring, image.bytes) or_return
	queue.enqueue(&u.pending, Texture_Upload{
		texture = texture,
		usage = usage,
		staging = staging,
		layer = u32(layer),
	})

	return true	
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
		srcStageMask = {},
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
		size = staging_slice_size(upload.staging),
	}

	vk.CmdCopyBuffer(
		commands,
		upload.staging.buffer_handle,
		upload.buffer.handle,
		1, &buffer_copy,
	)

	append(barriers, {
		sType = .BUFFER_MEMORY_BARRIER_2,
		srcStageMask = {.TRANSFER},
		srcAccessMask = {.TRANSFER_WRITE},
		dstStageMask = upload.usage.stages,
		dstAccessMask = upload.usage.access,
		buffer = upload.buffer.handle,
		offset = upload.offset,
		size = staging_slice_size(upload.staging),
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
