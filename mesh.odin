package main

import hm "core:container/handle_map"

Mesh_Handle :: distinct hm.Handle64

Mesh :: struct {
	vertex_count: int,
	attributes:   Vertex_Attributes,
	indices:      Vertex_Indices,
}

Mesh_Error :: enum {
	None = 0,
	Invalid_Handle,
	Out_Of_Gpu_Memory,
	Out_Of_Staging_Memory,
	Invalid_Vertex_Count,
	Invalid_Divisor,
	Divisor_Requires_Non_Indexed,
	Invalid_Encoding_For_Attribute,
	Data_Size_Not_Multiple_Of_Encoding,
	Data_Too_Short,
	Vertex_Count_Not_Multiple_Of_Divisor,
	Vertex_Count_Incompatible_With_Topology,
	Empty_Indices,
	Index_Out_Of_Range,
	Index_Count_Incompatible_With_Topology,
	Too_Many_Vertices_For_Index_Type,
}

Vertex_Attribute_Data :: struct {
	encoding: Vertex_Attribute_Encoding,
	divisor:  Maybe(int),
	data:     []byte,
}

Vertex_Attribute :: enum {
	Position,
	Normal,
	Tangent,
	Tex_Coord_0,
	Tex_Coord_1,
	Color,
	Joints,
	Weights,
	Custom_0,
	Custom_1,
	Custom_2,
	Custom_3,
	Custom_4,
	Custom_5,
	Custom_6,
	Custom_7,
}

Vertex_Attribute_Encoding :: enum {
	F32x1,
	F32x2,
	F32x3,
	F32x4,
	F16x2,
	F16x4,
	U32x1,
	U32x2,
	U32x3,
	U32x4,
	U16x2,
	U16x4,
	U8x4,
	Snorm16x2,
	Snorm16x4,
	Unorm16x2,
	Unorm16x4,
	Snorm8x4,
	Unorm8x4,
	Oct16,
}

Vertex_Attributes :: [Vertex_Attribute]Maybe(Vertex_Attribute_Data)

Vertex_Indices :: union #shared_nil {
	[]u16,
	[]u32,
}

Vertex_Attribute_Set :: bit_set[Vertex_Attribute;u32]

Vertex_Attribute_Encoding_Set :: bit_set[Vertex_Attribute_Encoding;u32]

ALL_VERTEX_ATTRIBUTE_ENCODINGS :: ~Vertex_Attribute_Encoding_Set{}

SUPPORTED_VERTEX_ATTRIBUTE_ENCODINGS := [Vertex_Attribute]Vertex_Attribute_Encoding_Set {
	.Position    = {.F32x3, .F16x4, .Snorm16x4, .Unorm16x4},
	.Normal      = {.F32x3, .Oct16, .Snorm16x4, .Snorm8x4},
	.Tangent     = {.F32x4, .Snorm16x4, .Snorm8x4},
	.Tex_Coord_0 = {.F32x2, .F16x2, .Unorm16x2, .Snorm16x2},
	.Tex_Coord_1 = {.F32x2, .F16x2, .Unorm16x2, .Snorm16x2},
	.Color       = {.F32x4, .F16x4, .Unorm16x4, .Unorm8x4},
	.Joints      = {.U16x4, .U8x4},
	.Weights     = {.F32x4, .Unorm16x4, .Unorm8x4},
	.Custom_0    = ALL_VERTEX_ATTRIBUTE_ENCODINGS,
	.Custom_1    = ALL_VERTEX_ATTRIBUTE_ENCODINGS,
	.Custom_2    = ALL_VERTEX_ATTRIBUTE_ENCODINGS,
	.Custom_3    = ALL_VERTEX_ATTRIBUTE_ENCODINGS,
	.Custom_4    = ALL_VERTEX_ATTRIBUTE_ENCODINGS,
	.Custom_5    = ALL_VERTEX_ATTRIBUTE_ENCODINGS,
	.Custom_6    = ALL_VERTEX_ATTRIBUTE_ENCODINGS,
	.Custom_7    = ALL_VERTEX_ATTRIBUTE_ENCODINGS,
}

VERTEX_ATTRIBUTE_ENCODING_SIZE := [Vertex_Attribute_Encoding]int {
	.F32x1     = 4,
	.F32x2     = 8,
	.F32x3     = 12,
	.F32x4     = 16,
	.F16x2     = 4,
	.F16x4     = 8,
	.U32x1     = 4,
	.U32x2     = 8,
	.U32x3     = 12,
	.U32x4     = 16,
	.U16x2     = 4,
	.U16x4     = 8,
	.U8x4      = 4,
	.Snorm16x2 = 4,
	.Snorm16x4 = 8,
	.Unorm16x2 = 4,
	.Unorm16x4 = 8,
	.Snorm8x4  = 4,
	.Unorm8x4  = 4,
	.Oct16     = 4,
}

@(require_results)
mesh_attribute_set :: proc(mesh: Mesh) -> Vertex_Attribute_Set {
	attribute_set := Vertex_Attribute_Set{}
	for data, attribute in mesh.attributes {
		if data != nil {
			attribute_set |= {attribute}
		}
	}
	return attribute_set
}

@(require_results)
mesh_attribute_size :: proc(mesh: Mesh, attribute: Vertex_Attribute) -> int {
	data, ok := mesh.attributes[attribute].?
	if !ok {
		return 0
	}

	divisor := data.divisor.? or_else 1
	return (mesh.vertex_count / divisor) * VERTEX_ATTRIBUTE_ENCODING_SIZE[data.encoding]
}

@(require_results)
mesh_validate :: proc(mesh: Mesh) -> Mesh_Error {
	if mesh.vertex_count < 0 || u64(mesh.vertex_count) > u64(max(u32)) {
		return .Invalid_Vertex_Count
	}

	for maybe_data, attribute in mesh.attributes {
		data := maybe_data.? or_continue

		if data.encoding not_in SUPPORTED_VERTEX_ATTRIBUTE_ENCODINGS[attribute] {
			return .Invalid_Encoding_For_Attribute
		}

		divisor := data.divisor.? or_else 1
		if divisor <= 0 {
			return .Invalid_Divisor
		}
		if divisor > 1 && mesh.indices != nil {
			return .Divisor_Requires_Non_Indexed
		}

		if mesh.vertex_count % divisor != 0 {
			return .Vertex_Count_Not_Multiple_Of_Divisor
		}

		size := VERTEX_ATTRIBUTE_ENCODING_SIZE[data.encoding]
		if len(data.data) % size != 0 {
			return .Data_Size_Not_Multiple_Of_Encoding
		}
		if len(data.data) / size < mesh.vertex_count / divisor {
			return .Data_Too_Short
		}
	}

	switch indices in mesh.indices {
	case []u32:
		check_indices(indices, mesh.vertex_count) or_return
	case []u16:
		check_indices(indices, mesh.vertex_count) or_return
	case nil:
		if mesh.vertex_count % 3 != 0 {
			return .Vertex_Count_Incompatible_With_Topology
		}
	}

	return .None
}

@(private = "file")
check_indices :: proc(indices: []$T, vertex_count: int) -> Mesh_Error {
	if u64(vertex_count) > u64(max(T)) + 1 {
		return .Too_Many_Vertices_For_Index_Type
	}

	if len(indices) == 0 {
		return .Empty_Indices
	}

	if len(indices) % 3 != 0 {
		return .Index_Count_Incompatible_With_Topology
	}

	for index in indices {
		if u64(index) >= u64(vertex_count) {
			return .Index_Out_Of_Range
		}
	}

	return .None
}
