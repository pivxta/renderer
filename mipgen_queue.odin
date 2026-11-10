package main
import vk "vendor:vulkan"

Mipgen_Queue :: struct {
	pending: [dynamic]Mipgen,
}

Mipgen :: struct {
	texture: Texture,
	usage: Resource_Usage,
}

mipgen_queue_init :: proc(mipgen_queue: ^Mipgen_Queue, allocator := context.allocator) {
	assert(mipgen_queue != nil)
	mipgen_queue.pending = make([dynamic]Mipgen, allocator)
}

mipgen_queue_destroy :: proc(mipgen_queue: ^Mipgen_Queue) {
	if mipgen_queue == nil {
		return
	}
	delete(mipgen_queue.pending)
	mipgen_queue^ = {}
}

mipgen_enqueue :: proc(
	mipgen_queue: ^Mipgen_Queue, 
	texture: Texture,
	usage: Resource_Usage,
) {
	assert(mipgen_queue != nil)

	if texture.mip_levels > 1 {
		append(&mipgen_queue.pending, {
			texture = texture,
			usage = usage,
		})
	}
}

mipgen_queue_record_commands :: proc(mipgen_queue: ^Mipgen_Queue, commands: vk.CommandBuffer) {
	assert(mipgen_queue != nil)

	max_mip_levels := u32(0)
	for mipgen in mipgen_queue.pending {
		max_mip_levels = max(max_mip_levels, mipgen.texture.mip_levels)
	}

	barriers := make([dynamic]vk.ImageMemoryBarrier2, context.temp_allocator)
	for level in 1..<max_mip_levels {
		clear(&barriers)

		for mipgen in mipgen_queue.pending {
			if mipgen.texture.mip_levels > level {
				if level > 1 { 
					append(&barriers, {
						sType = .IMAGE_MEMORY_BARRIER_2,
						image = mipgen.texture.handle,
						srcStageMask = {.COPY, .BLIT},
						srcAccessMask = {.TRANSFER_WRITE},
						dstStageMask = {.BLIT},
						dstAccessMask = {.TRANSFER_READ},
						oldLayout = .TRANSFER_DST_OPTIMAL,
						newLayout = .TRANSFER_SRC_OPTIMAL,
						subresourceRange = {
							aspectMask = mipgen.texture.full_view.aspect_mask,
							baseMipLevel = level - 1,
							levelCount = 1,
							baseArrayLayer = 0,
							layerCount = mipgen.texture.array_layers,
						},
					})
				}
				append(&barriers, {
					sType = .IMAGE_MEMORY_BARRIER_2,
					image = mipgen.texture.handle,
					srcStageMask = {.BLIT},
					srcAccessMask = {},
					dstStageMask = {.BLIT},
					dstAccessMask = {.TRANSFER_WRITE},
					oldLayout = .UNDEFINED,
					newLayout = .TRANSFER_DST_OPTIMAL,
					subresourceRange = {
						aspectMask = mipgen.texture.full_view.aspect_mask,
						baseMipLevel = level,
						levelCount = 1,
						baseArrayLayer = 0,
						layerCount = mipgen.texture.array_layers,
					},
				})
			}
		}

		if len(barriers) > 0 {
			vk.CmdPipelineBarrier2(commands, &vk.DependencyInfo {
				sType = .DEPENDENCY_INFO,
				imageMemoryBarrierCount = u32(len(barriers)),
				pImageMemoryBarriers = raw_data(barriers),
			})
		}

		for mipgen in mipgen_queue.pending {
			if mipgen.texture.mip_levels > level {
				src_width := max(mipgen.texture.extent.width >> (level - 1), 1)
				src_height := max(mipgen.texture.extent.height >> (level - 1), 1)
				dst_width := max(mipgen.texture.extent.width >> level, 1)
				dst_height := max(mipgen.texture.extent.height >> level, 1)
				
				src_subresource := vk.ImageSubresourceLayers {
					aspectMask = mipgen.texture.full_view.aspect_mask,
					baseArrayLayer = 0,
					layerCount = mipgen.texture.array_layers,
					mipLevel = level - 1,
				}
				src_offsets := [2]vk.Offset3D {
					{0, 0, 0}, {i32(src_width), i32(src_height), 1},
				}

				dst_subresource := vk.ImageSubresourceLayers {
					aspectMask = mipgen.texture.full_view.aspect_mask,
					baseArrayLayer = 0,
					layerCount = mipgen.texture.array_layers,
					mipLevel = level,
				}
				dst_offsets := [2]vk.Offset3D {
					{0, 0, 0}, {i32(dst_width), i32(dst_height), 1},
				}

				image_blit := vk.ImageBlit {
					srcSubresource = src_subresource,
					srcOffsets = src_offsets,
					dstSubresource = dst_subresource,
					dstOffsets = dst_offsets,
				}

				vk.CmdBlitImage(
					commands,
					mipgen.texture.handle, .TRANSFER_SRC_OPTIMAL,
					mipgen.texture.handle, .TRANSFER_DST_OPTIMAL,
					1, &image_blit, .LINEAR,
				)
			}
		}
	}

	clear(&barriers)
	for mipgen in mipgen_queue.pending {
		append(&barriers, {
			sType = .IMAGE_MEMORY_BARRIER_2,
			image = mipgen.texture.handle,
			srcStageMask = {.BLIT},
			srcAccessMask = {},
			dstStageMask = mipgen.usage.stages,
			dstAccessMask = mipgen.usage.access,
			oldLayout = .TRANSFER_SRC_OPTIMAL,
			newLayout = mipgen.usage.layout,
			subresourceRange = {
				aspectMask = mipgen.texture.full_view.aspect_mask,
				baseMipLevel = 0,
				levelCount = mipgen.texture.mip_levels - 1,
				baseArrayLayer = 0,
				layerCount = mipgen.texture.array_layers,
			},
		})

		append(&barriers, {
			sType = .IMAGE_MEMORY_BARRIER_2,
			image = mipgen.texture.handle,
			srcStageMask = {.BLIT},
			srcAccessMask = {.TRANSFER_WRITE},
			dstStageMask = mipgen.usage.stages,
			dstAccessMask = mipgen.usage.access,
			oldLayout = .TRANSFER_DST_OPTIMAL,
			newLayout = mipgen.usage.layout,
			subresourceRange = {
				aspectMask = mipgen.texture.full_view.aspect_mask,
				baseMipLevel = mipgen.texture.mip_levels - 1,
				levelCount = 1,
				baseArrayLayer = 0,
				layerCount = mipgen.texture.array_layers,
			},
		})
	}

	if len(barriers) > 0 {
		vk.CmdPipelineBarrier2(commands, &vk.DependencyInfo {
			sType = .DEPENDENCY_INFO,
			imageMemoryBarrierCount = u32(len(barriers)),
			pImageMemoryBarriers = raw_data(barriers),
		})
	}

	clear(&mipgen_queue.pending)
}
