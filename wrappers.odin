package main
import "core:log"
import "core:slice"
import vk "vendor:vulkan"
import "third_party/vma"

Texture :: struct {
	handle: vk.Image,
	allocation: vma.Allocation,
	allocated: bool,
	full_view: Texture_View,

	type: vk.ImageType,
	usage: vk.ImageUsageFlags,
	format: vk.Format,
	extent: vk.Extent3D,
	samples: vk.SampleCountFlags,
	mip_levels: u32,
	array_layers: u32,
	is_cube: bool,
}

Texture_View :: struct {
	handle: vk.ImageView,

	type: vk.ImageViewType,
	aspect_mask: vk.ImageAspectFlags,
	base_mip_level: u32,
	mip_level_count: u32,
	base_array_layer: u32,
	array_layer_count: u32,
}

Texture_Access_Error :: enum {
	None = 0,
	Subresource_Range_Out_Of_Bounds,
	Empty_Subresource_Range,
	Invalid_View_Configuration,
}

Texture_Init_Error :: enum {
	None = 0,
	Allocation_Failed,
}

Texture_Error :: union #shared_nil {
	Texture_Access_Error,
	Texture_Init_Error,
	vk.Result,
}

Buffer :: struct {
	handle: vk.Buffer,
	allocation: vma.Allocation,
	mapped: []byte,
	address: Device_Address,
	size: Device_Size,
}

Buffer_Init_Error :: enum {
	None = 0,
	Zero_Sized,
	No_Device_Address_Available,
}

Buffer_Access_Error :: enum {
	None = 0,
	Flush_Out_Of_Bounds,
}

Buffer_Error :: union #shared_nil {
	Buffer_Init_Error,
	Buffer_Access_Error,
	vk.Result,
}

@(require_results)
texture_init :: proc(
	texture: ^Texture, 
	device: Device,
	type: vk.ImageType,
	usage: vk.ImageUsageFlags,
	format: vk.Format,
	extent: vk.Extent3D,
	samples: vk.SampleCountFlags = {._1},
	mip_levels: u32 = 1,
	array_layers: u32 = 1,
	is_cube := false,
	location := #caller_location,
) -> Texture_Error {
	assert(texture != nil, loc=location)

	create_info := vk.ImageCreateInfo {
		sType = .IMAGE_CREATE_INFO,
		flags = {.CUBE_COMPATIBLE} if is_cube else {},
		imageType = type,
		usage = usage,
		format = format,
		extent = extent,
		samples = samples,
		mipLevels = mip_levels,
		arrayLayers = array_layers,
	}
	alloc_info := vma.AllocationCreateInfo {
		usage = .AUTO,
	}

	texture_destroy(texture, device)
	texture^ = {}

	vma.CreateImage(
		device.allocator, 
		create_info, alloc_info, 
		&texture.handle, &texture.allocation, nil,
	) or_return

	if texture.handle == 0 {
		log.error("Failed to create texture, out of memory or invalid configuration", 
		          location=location)
		return Texture_Init_Error.Allocation_Failed
	}

	texture.allocated = true
	texture.type = type
	texture.usage = usage
	texture.format = format
	texture.extent = extent
	texture.samples = samples
	texture.mip_levels = mip_levels
	texture.array_layers = array_layers
	texture.is_cube = is_cube
	if err := view_create(&texture.full_view, texture^, device); err != nil {
		texture_destroy(texture, device)
		return err
	}

	return nil
}

@(require_results)
texture_wrap :: proc(
	texture: ^Texture, 
	device: Device,
	image: vk.Image,
	type: vk.ImageType,
	usage: vk.ImageUsageFlags,
	format: vk.Format,
	extent: vk.Extent3D,
	samples: vk.SampleCountFlags = {._1},
	mip_levels: u32 = 1,
	array_layers: u32 = 1,
	is_cube := false,
	location := #caller_location,
) -> Texture_Error {
	assert(texture != nil, loc=location)

	texture_destroy(texture, device)
	texture^ = {}

	assert(image != 0, loc=location)
	texture.allocated = false
	texture.handle = image
	texture.type = type
	texture.usage = usage
	texture.format = format
	texture.extent = extent
	texture.samples = samples
	texture.mip_levels = mip_levels
	texture.array_layers = array_layers
	texture.is_cube = is_cube
	if err := view_create(&texture.full_view, texture^, device); err != nil {
		texture_destroy(texture, device)
		return err
	}

	return nil
}

texture_destroy :: proc(texture: ^Texture, device: Device) {
	view_destroy(&texture.full_view, device)
	if texture.allocated && texture.handle != 0 {
		vma.DestroyImage(device.allocator, texture.handle, texture.allocation)
	}
	texture^ = {}
}

@(require_results)
view_create :: proc(
	view: ^Texture_View,
	texture: Texture, 
	device: Device,
	base_mip_level: u32 = 0,
	mip_level_count: Maybe(u32) = nil,
	base_array_layer: u32 = 0,
	array_layer_count: Maybe(u32) = nil,
	location := #caller_location,
) -> Texture_Error {
	assert(view != nil, loc=location)
	assert(texture.handle != 0, loc=location)
	assert(texture.mip_levels != 0, loc=location)
	assert(texture.array_layers != 0, loc=location)

	view^ = {}

	if base_mip_level >= texture.mip_levels {
		log.errorf("Invalid subresource range for texture view creation. " +
			       "Base mip level is out of bounds (base_mip_level: %v, " +
				   "texture_mip_level_count: %v)",
		           base_mip_level, texture.mip_levels, location=location)
		return Texture_Access_Error.Subresource_Range_Out_Of_Bounds
	}
	if base_array_layer >= texture.array_layers {
		log.errorf("Invalid subresource range for texture view creation. " +
			       "Base array layer is out of bounds (base_array_layer: %v," +
				   "texture_array_layer_count: %v)",
		           base_array_layer, texture.array_layers, location=location)
		return Texture_Access_Error.Subresource_Range_Out_Of_Bounds
	}

	level_count: u32
	layer_count: u32

	if mip_level_count == nil {
		level_count = texture.mip_levels - base_mip_level
	} else if base_mip_level + mip_level_count.? > texture.mip_levels {
		log.errorf("Invalid subresource range for texture view creation. " +
			       "Mip level count is out of bounds (base_mip_level: %v, " +
				   "mip_level_count: %v, texture_mip_level_count: %v)",
		           base_mip_level, mip_level_count.?, texture.mip_levels, location=location)
		return Texture_Access_Error.Subresource_Range_Out_Of_Bounds
 	} else {
		level_count = mip_level_count.?
	}

	if array_layer_count == nil {
		layer_count = texture.array_layers - base_array_layer
	} else if base_array_layer + array_layer_count.? > texture.array_layers {
		log.errorf("Invalid subresource range for texture view creation. " +
			       "Array layer count is out of bounds (base_array_layer: %v, " +
				   "array_layer_count: %v, texture_array_layer_count: %v)",
		           base_array_layer, array_layer_count.?, texture.array_layers, location=location)
		return Texture_Access_Error.Subresource_Range_Out_Of_Bounds
	} else {
		layer_count = array_layer_count.?
	}

	if level_count == 0 || layer_count == 0 {
		return Texture_Access_Error.Empty_Subresource_Range
	}

	aspect_mask := format_aspect_mask(texture.format)
	view_type, ok := full_view_type(texture)
	if !ok {
		return Texture_Access_Error.Invalid_View_Configuration
	}

	view_info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = texture.handle,
		format = texture.format,
		viewType = view_type,
		subresourceRange = vk.ImageSubresourceRange {
			aspectMask = aspect_mask,
			baseMipLevel = base_mip_level,
			levelCount = level_count,
			baseArrayLayer = base_array_layer,
			layerCount = layer_count,
		},
	}

	vk.CreateImageView(device.logical, &view_info, nil, &view.handle) or_return

	view.type = view_type
	view.aspect_mask = aspect_mask
	view.base_mip_level = base_mip_level
	view.base_array_layer = base_array_layer
	view.mip_level_count = level_count
	view.array_layer_count = layer_count

	return nil
}

view_destroy :: proc(view: ^Texture_View, device: Device) {
	if view == nil {
		return
	}

	if view.handle != 0 {
		vk.DestroyImageView(device.logical, view.handle, nil)
	}
	
	view^ = {}
}

view_subresource_range :: proc(view: Texture_View) -> vk.ImageSubresourceRange {
	return {
		aspectMask = view.aspect_mask,
		baseMipLevel = view.base_mip_level,
		levelCount = view.mip_level_count,
		baseArrayLayer = view.base_array_layer,
		layerCount = view.array_layer_count,
	}
}

full_view_type :: proc(texture: Texture) -> (vk.ImageViewType, bool) {
	if texture.array_layers == 1 {
		if texture.is_cube {
			log.errorf("Trying to create view of invalid cube texture. " +
			           "Cube textures must have 6 array layers and " +
			           "cube texture arrays must have a multiple of 6")
			return {}, false
		}

		switch texture.type {
		case .D1: return .D1, true	
		case .D2: return .D2, true
		case .D3: return .D3, true
		}
	} else {
		if texture.is_cube {
			if texture.array_layers % 6 != 0 {
				log.errorf("Trying to create view of invalid cube texture. " +
						   "Cube textures must have 6 array layers and " +
						   "cube texture arrays must have a multiple of 6")
				return {}, false
			}

			cubes := texture.array_layers / 6
			if cubes == 1 {
				return .CUBE, true
			} else {
				return .CUBE_ARRAY, true
			}
		}

		switch texture.type {
		case .D1: return .D1_ARRAY, true
		case .D2: return .D2_ARRAY, true
		case .D3:
			log.errorf("Arrays of 3D textures are not supported")
			return .D3, false	
		}
	}
	return {}, false
}

format_aspect_mask :: proc(format: vk.Format) -> vk.ImageAspectFlags {
	#partial switch format {
	case .UNDEFINED:
		return {}

	case .D16_UNORM, .X8_D24_UNORM_PACK32, .D32_SFLOAT:
		return {.DEPTH}

	case .S8_UINT:
		return {.STENCIL}

	case .D16_UNORM_S8_UINT, .D24_UNORM_S8_UINT, .D32_SFLOAT_S8_UINT:
		return {.DEPTH, .STENCIL}

	case .G8_B8_R8_3PLANE_420_UNORM,
	     .G8_B8_R8_3PLANE_422_UNORM,
	     .G8_B8_R8_3PLANE_444_UNORM,
	     .G10X6_B10X6_R10X6_3PLANE_420_UNORM_3PACK16,
	     .G10X6_B10X6_R10X6_3PLANE_422_UNORM_3PACK16,
	     .G10X6_B10X6_R10X6_3PLANE_444_UNORM_3PACK16,
	     .G12X4_B12X4_R12X4_3PLANE_420_UNORM_3PACK16,
	     .G12X4_B12X4_R12X4_3PLANE_422_UNORM_3PACK16,
	     .G12X4_B12X4_R12X4_3PLANE_444_UNORM_3PACK16,
	     .G16_B16_R16_3PLANE_420_UNORM,
	     .G16_B16_R16_3PLANE_422_UNORM,
	     .G16_B16_R16_3PLANE_444_UNORM:
		return {.PLANE_0, .PLANE_1, .PLANE_2}

	case .G8_B8R8_2PLANE_420_UNORM,
	     .G8_B8R8_2PLANE_422_UNORM,
	     .G8_B8R8_2PLANE_444_UNORM,
	     .G10X6_B10X6R10X6_2PLANE_420_UNORM_3PACK16,
	     .G10X6_B10X6R10X6_2PLANE_422_UNORM_3PACK16,
	     .G10X6_B10X6R10X6_2PLANE_444_UNORM_3PACK16,
	     .G12X4_B12X4R12X4_2PLANE_420_UNORM_3PACK16,
	     .G12X4_B12X4R12X4_2PLANE_422_UNORM_3PACK16,
	     .G12X4_B12X4R12X4_2PLANE_444_UNORM_3PACK16,
	     .G16_B16R16_2PLANE_420_UNORM,
	     .G16_B16R16_2PLANE_422_UNORM,
	     .G16_B16R16_2PLANE_444_UNORM:
		return {.PLANE_0, .PLANE_1}

	case:
		return {.COLOR}
	}
}

@(require_results)
buffer_init :: proc(
	buffer: ^Buffer,
	device: Device, 
	#any_int size: Device_Size,
	buffer_usage: vk.BufferUsageFlags,
	memory_usage: vma.MemoryUsage = .AUTO,
	memory_flags: vma.AllocationCreateFlags = {},
	location := #caller_location,
) -> Buffer_Error {
	assert(buffer != nil, loc=location)

	if size == 0 {
		log.error("Buffer cannot be zero-sized", location=location)
		return Buffer_Init_Error.Zero_Sized
	}

	buffer_destroy(buffer, device)
	buffer^ = {}

	buffer_info := vk.BufferCreateInfo {
		sType = .BUFFER_CREATE_INFO,
		usage = buffer_usage,
		size = Device_Size(size),
	}
	alloc_create_info := vma.AllocationCreateInfo {
		usage = memory_usage,
		flags = memory_flags,
	}

	handle: vk.Buffer
	address: Device_Address
	allocation: vma.Allocation
	alloc_info: vma.AllocationInfo

	vma.CreateBuffer(
		device.allocator, 
		buffer_info, 
		alloc_create_info, 
		&handle, &allocation,
		&alloc_info,
	) or_return

	if .SHADER_DEVICE_ADDRESS in buffer_usage {
		address_info := vk.BufferDeviceAddressInfo {
			sType = .BUFFER_DEVICE_ADDRESS_INFO,
			buffer = handle,
		}

		address = vk.GetBufferDeviceAddress(device.logical, &address_info)
		if address == 0 {
			log.error("Buffer requested shader device address, but none was assigned", 
			          location=location)
			vma.DestroyBuffer(device.allocator, handle, allocation)
			return Buffer_Init_Error.No_Device_Address_Available
		}
	}

	buffer.handle = handle
	buffer.size = size
	buffer.address = address
	buffer.allocation = allocation
	if alloc_info.pMappedData != nil {
		buffer.mapped = slice.bytes_from_ptr(alloc_info.pMappedData, int(size))
	}

	return nil
}

@(require_results)
buffer_flush :: proc(
	buffer: ^Buffer, 
	device: Device, 
	#any_int offset: Device_Size = 0,
	#any_int size: Device_Size = 0,
	location := #caller_location,
) -> Buffer_Error {
	assert(buffer != nil, loc=location)

	if offset > buffer.size {
		log.errorf("Trying to flush buffer out of its bounds (offset: %v, buffer_size: %v)", 
		           offset, buffer.size, location=location)
		return Buffer_Access_Error.Flush_Out_Of_Bounds
	}
	
	flush_size: Device_Size
	if size == 0 {
		flush_size = buffer.size - offset
	} else {
		flush_size = min(size, buffer.size - offset)
	}

	vma.FlushAllocation(
		device.allocator,
		buffer.allocation,
		offset, flush_size,
	) or_return

	return nil
}

buffer_destroy :: proc(buffer: ^Buffer, device: Device) {
	if buffer == nil {
		return
	}

	if buffer.handle != 0 {
		vma.DestroyBuffer(device.allocator, buffer.handle, buffer.allocation)
	}
	buffer^ = {}
}
