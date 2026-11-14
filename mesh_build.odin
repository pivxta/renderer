package main

import "core:math"
import "core:math/linalg"
import "core:slice"

Shading_Mode :: enum {
	Smooth,
	Flat,
}

PRIMITIVE_DEFAULT_ATTRIBUTES :: Vertex_Attribute_Set{.Position, .Normal, .Tangent, .Tex_Coord_0}

@(require_results)
make_cube :: proc(
	size := f32(1.0),
	attributes := PRIMITIVE_DEFAULT_ATTRIBUTES,
	allocator := context.allocator,
) -> Mesh {
	return make_cuboid({size, size, size}, attributes, allocator)
}

@(require_results)
make_cuboid :: proc(
	size := [3]f32{1.0, 1.0, 1.0},
	attributes := PRIMITIVE_DEFAULT_ATTRIBUTES,
	allocator := context.allocator,
) -> Mesh {
	b: Mesh_Builder
	mesh_builder_init(&b, attributes, allocator)
	mesh_builder_add_cuboid(&b, size)
	return mesh_builder_take_mesh(&b)
}

@(require_results)
make_sphere :: proc(
	radius := f32(0.5),
	stacks := 16,
	slices := 16,
	shading := Shading_Mode.Smooth,
	attributes := PRIMITIVE_DEFAULT_ATTRIBUTES,
	allocator := context.allocator,
) -> Mesh {
	b: Mesh_Builder
	mesh_builder_init(&b, attributes, allocator)
	mesh_builder_add_sphere(&b, radius, stacks, slices, shading)
	return mesh_builder_take_mesh(&b)
}

@(require_results)
make_cylinder :: proc(
	radius := f32(0.5),
	height := f32(1.0),
	slices := 16,
	shading := Shading_Mode.Smooth,
	attributes := PRIMITIVE_DEFAULT_ATTRIBUTES,
	allocator := context.allocator,
) -> Mesh {
	b: Mesh_Builder
	mesh_builder_init(&b, attributes, allocator)
	mesh_builder_add_cylinder(&b, radius, height, slices, shading)
	return mesh_builder_take_mesh(&b)
}

delete_mesh :: proc(mesh: Mesh, allocator := context.allocator) {
	for maybe_data in mesh.attributes {
		if data, ok := maybe_data.?; ok {
			delete(data.data, allocator)
		}
	}
	switch indices in mesh.indices {
	case []u16:
		delete(indices, allocator)
	case []u32:
		delete(indices, allocator)
	}
}

Mesh_Builder :: struct {
	attributes:   Vertex_Attribute_Set,
	indices:      [dynamic]u32,
	positions:    [dynamic][3]f32,
	normals:      [dynamic][3]f32,
	tangents:     [dynamic][4]f32,
	tex_coords_0: [dynamic][2]f32,
	tex_coords_1: [dynamic][2]f32,
	color:        [dynamic][4]f32,
	joints:       [dynamic][4]u16,
	weights:      [dynamic][4]f32,
}

Builder_Vertex :: struct {
	position:    [3]f32,
	normal:      [3]f32,
	tangent:     [4]f32,
	tex_coord_0: [2]f32,
	tex_coord_1: [2]f32,
	color:       [4]f32,
	joints:      [4]u16,
	weights:     [4]f32,
}

BUILDER_VERTEX_DEFAULT :: Builder_Vertex {
	normal  = {0, 1, 0},
	tangent = {1, 0, 0, 1},
	color   = {1, 1, 1, 1},
	weights = {1, 0, 0, 0},
}

BUILDER_SUPPORTED_ATTRIBUTES :: Vertex_Attribute_Set {
	.Position,
	.Normal,
	.Tangent,
	.Tex_Coord_0,
	.Tex_Coord_1,
	.Color,
	.Joints,
	.Weights,
}

mesh_builder_init :: proc(
	builder: ^Mesh_Builder,
	attributes: Vertex_Attribute_Set,
	allocator := context.allocator,
) {
	assert(.Position in attributes, "Mesh_Builder requires .Position")
	assert(
		attributes <= BUILDER_SUPPORTED_ATTRIBUTES,
		"Mesh_Builder does not support custom attributes",
	)

	builder^ = {}
	builder.attributes = attributes
	builder.indices = make([dynamic]u32, allocator)
	builder.positions = make([dynamic][3]f32, allocator)
	builder.normals = make([dynamic][3]f32, allocator)
	builder.tangents = make([dynamic][4]f32, allocator)
	builder.tex_coords_0 = make([dynamic][2]f32, allocator)
	builder.tex_coords_1 = make([dynamic][2]f32, allocator)
	builder.color = make([dynamic][4]f32, allocator)
	builder.joints = make([dynamic][4]u16, allocator)
	builder.weights = make([dynamic][4]f32, allocator)
}

mesh_builder_destroy :: proc(builder: ^Mesh_Builder) {
	delete(builder.indices)
	delete(builder.positions)
	delete(builder.normals)
	delete(builder.tangents)
	delete(builder.tex_coords_0)
	delete(builder.tex_coords_1)
	delete(builder.color)
	delete(builder.joints)
	delete(builder.weights)
	builder^ = {}
}

mesh_builder_clear :: proc(builder: ^Mesh_Builder) {
	clear(&builder.indices)
	clear(&builder.positions)
	clear(&builder.normals)
	clear(&builder.tangents)
	clear(&builder.tex_coords_0)
	clear(&builder.tex_coords_1)
	clear(&builder.color)
	clear(&builder.joints)
	clear(&builder.weights)
}

@(require_results)
mesh_builder_vertex_count :: proc(b: ^Mesh_Builder) -> int {
	return len(b.positions)
}

mesh_builder_add_vertex :: proc(b: ^Mesh_Builder, v: Builder_Vertex) -> (index: u32) {
	index = u32(len(b.positions))

	append(&b.positions, v.position)
	if .Normal in b.attributes {append(&b.normals, v.normal)}
	if .Tangent in b.attributes {append(&b.tangents, v.tangent)}
	if .Tex_Coord_0 in b.attributes {append(&b.tex_coords_0, v.tex_coord_0)}
	if .Tex_Coord_1 in b.attributes {append(&b.tex_coords_1, v.tex_coord_1)}
	if .Color in b.attributes {append(&b.color, v.color)}
	if .Joints in b.attributes {append(&b.joints, v.joints)}
	if .Weights in b.attributes {append(&b.weights, v.weights)}
	return
}

mesh_builder_add_triangle :: proc(b: ^Mesh_Builder, v0, v1, v2: u32) {
	assert(b != nil)
	append(&b.indices, v0, v1, v2)
}

mesh_builder_add_quad :: proc(b: ^Mesh_Builder, bl, br, tr, tl: u32) {
	mesh_builder_add_triangle(b, bl, br, tr)
	mesh_builder_add_triangle(b, bl, tr, tl)
}

mesh_builder_add_flat_triangle :: proc(b: ^Mesh_Builder, v0, v1, v2: Builder_Vertex) {
	normal := -linalg.normalize(linalg.cross(v1.position - v0.position, v2.position - v0.position))
	tangent := face_tangent(v0, v1, v2, normal)
	i0 := mesh_builder_add_vertex(b, with_frame(v0, normal, tangent))
	i1 := mesh_builder_add_vertex(b, with_frame(v1, normal, tangent))
	i2 := mesh_builder_add_vertex(b, with_frame(v2, normal, tangent))
	mesh_builder_add_triangle(b, i0, i1, i2)
}

mesh_builder_add_flat_quad :: proc(b: ^Mesh_Builder, bl, br, tr, tl: Builder_Vertex) {
	normal := -linalg.normalize(linalg.cross(tr.position - bl.position, tl.position - br.position))
	tangent := face_tangent(bl, br, tr, normal)
	ibl := mesh_builder_add_vertex(b, with_frame(bl, normal, tangent))
	ibr := mesh_builder_add_vertex(b, with_frame(br, normal, tangent))
	itr := mesh_builder_add_vertex(b, with_frame(tr, normal, tangent))
	itl := mesh_builder_add_vertex(b, with_frame(tl, normal, tangent))
	mesh_builder_add_quad(b, ibl, ibr, itr, itl)
}

@(require_results)
mesh_builder_to_mesh :: proc(b: ^Mesh_Builder) -> (mesh: Mesh) {
	mesh.vertex_count = len(b.positions)

	attach_data(&mesh, b.attributes, .Position, .F32x3, b.positions[:])
	attach_data(&mesh, b.attributes, .Normal, .F32x3, b.normals[:])
	attach_data(&mesh, b.attributes, .Tangent, .F32x4, b.tangents[:])
	attach_data(&mesh, b.attributes, .Tex_Coord_0, .F32x2, b.tex_coords_0[:])
	attach_data(&mesh, b.attributes, .Tex_Coord_1, .F32x2, b.tex_coords_1[:])
	attach_data(&mesh, b.attributes, .Color, .F32x4, b.color[:])
	attach_data(&mesh, b.attributes, .Joints, .U16x4, b.joints[:])
	attach_data(&mesh, b.attributes, .Weights, .F32x4, b.weights[:])

	if len(b.indices) > 0 {
		mesh.indices = b.indices[:]
	}
	return
}

@(require_results)
mesh_builder_take_mesh :: proc(b: ^Mesh_Builder) -> Mesh {
	shrink(&b.indices)
	shrink(&b.positions)
	shrink(&b.normals)
	shrink(&b.tangents)
	shrink(&b.tex_coords_0)
	shrink(&b.tex_coords_1)
	shrink(&b.color)
	shrink(&b.joints)
	shrink(&b.weights)

	mesh := mesh_builder_to_mesh(b)
	if len(b.indices) == 0 {
		delete(b.indices)
	}
	b^ = {}
	return mesh
}

@(private = "file")
attach_data :: proc(
	mesh: ^Mesh,
	enabled: Vertex_Attribute_Set,
	attribute: Vertex_Attribute,
	encoding: Vertex_Attribute_Encoding,
	data: []$E,
	location := #caller_location,
) {
	if attribute not_in enabled {
		return
	}
	assert(len(data) == mesh.vertex_count, "Mesh_Builder attribute arrays out of sync", location)
	assert(size_of(E) == VERTEX_ATTRIBUTE_ENCODING_SIZE[encoding], loc = location)
	mesh.attributes[attribute] = Vertex_Attribute_Data {
		encoding = encoding,
		data     = slice.to_bytes(data),
	}
}

@(private = "file")
make_vertex :: proc(
	position, normal: [3]f32,
	tangent: [4]f32,
	tex_coord: [2]f32,
) -> Builder_Vertex {
	v := BUILDER_VERTEX_DEFAULT
	v.position = position
	v.normal = normal
	v.tangent = tangent
	v.tex_coord_0 = tex_coord
	v.tex_coord_1 = tex_coord
	return v
}

@(private = "file")
with_frame :: proc(v: Builder_Vertex, normal: [3]f32, tangent: [4]f32) -> Builder_Vertex {
	result := v
	result.normal = normal
	result.tangent = tangent
	return result
}

@(private = "file")
face_tangent :: proc(v0, v1, v2: Builder_Vertex, normal: [3]f32) -> [4]f32 {
	e1, e2 := v1.position - v0.position, v2.position - v0.position
	d1, d2 := v1.tex_coord_0 - v0.tex_coord_0, v2.tex_coord_0 - v0.tex_coord_0
	r := d1.x * d2.y - d2.x * d1.y
	if abs(r) < 1e-12 {
		return v0.tangent
	}

	tangent := (e1 * d2.y - e2 * d1.y) / r
	bitangent := (e2 * d1.x - e1 * d2.x) / r
	tangent = linalg.normalize(tangent - normal * linalg.dot(normal, tangent))
	w: f32 = 1 if linalg.dot(linalg.cross(normal, tangent), bitangent) >= 0 else -1
	return {tangent.x, tangent.y, tangent.z, w}
}

@(private = "file")
Cuboid_Face :: struct {
	normal, right, up: [3]f32,
}

@(private = "file")
CUBOID_FACES :: [6]Cuboid_Face {
	{normal = {0, 0, -1}, right = {1, 0, 0}, up = {0, 1, 0}},
	{normal = {0, 0, 1}, right = {-1, 0, 0}, up = {0, 1, 0}},
	{normal = {1, 0, 0}, right = {0, 0, 1}, up = {0, 1, 0}},
	{normal = {-1, 0, 0}, right = {0, 0, -1}, up = {0, 1, 0}},
	{normal = {0, 1, 0}, right = {1, 0, 0}, up = {0, 0, 1}},
	{normal = {0, -1, 0}, right = {-1, 0, 0}, up = {0, 0, 1}},
}

mesh_builder_add_cube :: proc(b: ^Mesh_Builder, size: f32 = 1) {
	mesh_builder_add_cuboid(b, {size, size, size})
}

mesh_builder_add_cuboid :: proc(b: ^Mesh_Builder, size := [3]f32{1, 1, 1}) {
	h := size * 0.5
	for face in CUBOID_FACES {
		c := face.normal * h
		r := face.right * h
		u := face.up * h
		tangent := [4]f32{face.right.x, face.right.y, face.right.z, 1}

		bl := mesh_builder_add_vertex(b, make_vertex(c - r - u, face.normal, tangent, {0, 1}))
		br := mesh_builder_add_vertex(b, make_vertex(c + r - u, face.normal, tangent, {1, 1}))
		tr := mesh_builder_add_vertex(b, make_vertex(c + r + u, face.normal, tangent, {1, 0}))
		tl := mesh_builder_add_vertex(b, make_vertex(c - r + u, face.normal, tangent, {0, 0}))
		mesh_builder_add_quad(b, bl, br, tr, tl)
	}
}

mesh_builder_add_sphere :: proc(
	b: ^Mesh_Builder,
	radius: f32 = 0.5,
	stacks := 16,
	slices := 16,
	shading := Shading_Mode.Smooth,
) {
	assert(stacks >= 2 && slices >= 3)

	switch shading {
	case .Smooth:
		base := u32(mesh_builder_vertex_count(b))
		row := u32(slices + 1)
		for stack in 0 ..= stacks {
			for column in 0 ..= slices {
				mesh_builder_add_vertex(b, sphere_vertex(radius, stack, stacks, column, slices))
			}
		}
		for stack in 0 ..< stacks {
			for column in 0 ..< slices {
				tl := base + u32(stack) * row + u32(column)
				tr := tl + 1
				bl := tl + row
				br := bl + 1
				if stack == 0 {
					mesh_builder_add_triangle(b, bl, br, tr) // tl and tr are both the top pole
				} else if stack == stacks - 1 {
					mesh_builder_add_triangle(b, bl, tr, tl) // bl and br are both the bottom pole
				} else {
					mesh_builder_add_quad(b, bl, br, tr, tl)
				}
			}
		}

	case .Flat:
		for stack in 0 ..< stacks {
			for column in 0 ..< slices {
				tl := sphere_vertex(radius, stack, stacks, column, slices)
				tr := sphere_vertex(radius, stack, stacks, column + 1, slices)
				bl := sphere_vertex(radius, stack + 1, stacks, column, slices)
				br := sphere_vertex(radius, stack + 1, stacks, column + 1, slices)
				if stack == 0 {
					mesh_builder_add_flat_triangle(b, bl, br, tr)
				} else if stack == stacks - 1 {
					mesh_builder_add_flat_triangle(b, bl, tr, tl)
				} else {
					mesh_builder_add_flat_quad(b, bl, br, tr, tl)
				}
			}
		}
	}
}

@(private = "file")
sphere_vertex :: proc(radius: f32, stack, stacks, column, slices: int) -> Builder_Vertex {
	phi := math.PI * f32(stack) / f32(stacks) // 0 at the top pole
	sin_phi, cos_phi := math.sin(phi), math.cos(phi)
	if stack == 0 {
		sin_phi, cos_phi = 0, 1
	} else if stack == stacks {
		sin_phi, cos_phi = 0, -1
	}

	theta := math.TAU * f32(column) / f32(slices)
	sin_theta, cos_theta := math.sin(theta), math.cos(theta)

	normal := [3]f32{sin_phi * cos_theta, cos_phi, sin_phi * sin_theta}
	tangent := [4]f32{-sin_theta, 0, cos_theta, 1}
	tex_coord := [2]f32{f32(column) / f32(slices), f32(stack) / f32(stacks)}
	return make_vertex(normal * radius, normal, tangent, tex_coord)
}

mesh_builder_add_cylinder :: proc(
	b: ^Mesh_Builder,
	radius: f32 = 0.5,
	height: f32 = 1,
	slices := 16,
	shading := Shading_Mode.Smooth,
) {
	assert(slices >= 3)
	h := height * 0.5

	switch shading {
	case .Smooth:
		side := u32(mesh_builder_vertex_count(b))
		for column in 0 ..= slices {
			mesh_builder_add_vertex(
				b,
				cylinder_side_vertex(radius, h, column, slices, top = false),
			)
			mesh_builder_add_vertex(b, cylinder_side_vertex(radius, h, column, slices, top = true))
		}
		for column in 0 ..< u32(slices) {
			bl := side + column * 2
			tl := bl + 1
			br := bl + 2
			tr := bl + 3
			mesh_builder_add_quad(b, bl, br, tr, tl)
		}

	case .Flat:
		for column in 0 ..< slices {
			mesh_builder_add_flat_quad(
				b,
				cylinder_side_vertex(radius, h, column, slices, top = false),
				cylinder_side_vertex(radius, h, column + 1, slices, top = false),
				cylinder_side_vertex(radius, h, column + 1, slices, top = true),
				cylinder_side_vertex(radius, h, column, slices, top = true),
			)
		}
	}

	add_cylinder_cap(b, radius, h, slices, top = true)
	add_cylinder_cap(b, radius, -h, slices, top = false)
}

@(private = "file")
cylinder_side_vertex :: proc(
	radius, half_height: f32,
	column, slices: int,
	top: bool,
) -> Builder_Vertex {
	theta := math.TAU * f32(column) / f32(slices)
	sin_theta, cos_theta := math.sin(theta), math.cos(theta)

	normal := [3]f32{cos_theta, 0, sin_theta}
	tangent := [4]f32{-sin_theta, 0, cos_theta, 1}
	y := half_height if top else -half_height
	v: f32 = 0 if top else 1
	return make_vertex(
		normal * radius + {0, y, 0},
		normal,
		tangent,
		{f32(column) / f32(slices), v},
	)
}

@(private = "file")
add_cylinder_cap :: proc(b: ^Mesh_Builder, radius, y: f32, slices: int, top: bool) {
	normal := [3]f32{0, 1, 0} if top else [3]f32{0, -1, 0}
	tangent := [4]f32{1, 0, 0, 1} if top else [4]f32{-1, 0, 0, 1}

	center := mesh_builder_add_vertex(b, make_vertex({0, y, 0}, normal, tangent, {0.5, 0.5}))
	first := u32(mesh_builder_vertex_count(b))
	for column in 0 ..= slices {
		theta := math.TAU * f32(column) / f32(slices)
		c, s := math.cos(theta), math.sin(theta)
		tex_coord :=
			[2]f32{0.5 + 0.5 * c, 0.5 - 0.5 * s} if top else [2]f32{0.5 - 0.5 * c, 0.5 - 0.5 * s}
		mesh_builder_add_vertex(
			b,
			make_vertex({c * radius, y, s * radius}, normal, tangent, tex_coord),
		)
	}

	for column in 0 ..< u32(slices) {
		if top {
			mesh_builder_add_triangle(b, center, first + column, first + column + 1)
		} else {
			mesh_builder_add_triangle(b, center, first + column + 1, first + column)
		}
	}
}
