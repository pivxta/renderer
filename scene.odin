package main 
import "core:math"

Scene :: struct {
	camera: Camera,
	ambient_light: Ambient_Light,
	point_lights: [dynamic]Point_Light,
	directional_lights: [dynamic]Directional_Light,
}

Ambient_Light :: struct {
	illuminance: f32,
	color: [3]f32,
}

Point_Light :: struct {
	position: [3]f32,
	radius: f32,
	power: f32,
	color: [3]f32,
}

Directional_Light :: struct {
	direction: [3]f32,
	illuminance: f32,
	color: [3]f32,
}

Camera :: struct {
	transform: Affine_Transform,
	projection: Projection,
}

Projection :: union {
	Perspective_Projection,
	Orthographic_Projection,
}

Perspective_Projection :: struct {
	fov_radians: f32,
	near: f32,
	far: f32,
}

Orthographic_Projection :: struct {
	scale: f32,
	near: f32,
	far: f32,
}

get_view_to_clip_matrix :: proc (
	projection: Projection, 
	width: int, 
	height: int,
) -> matrix[4, 4]f32 {
	aspect := f32(width) / f32(height) if height != 0 else 0

	transform: matrix[4, 4]f32
	switch p in projection {
	case Perspective_Projection:
		transform = matrix4_perspective_reverse_z_infinite(
			fovy = p.fov_radians,
			aspect = aspect,
			near = p.near,
		)
	case Orthographic_Projection:
		transform = matrix4_orthographic_reverse_z(
			left = -0.5 * aspect * p.scale,
			right = 0.5 * aspect * p.scale,
			top = 0.5,
			bottom = -0.5,
			near = p.near,
			far = p.far,
		)
	}

	return transform
}

get_world_to_view_matrix :: proc(camera: Camera) -> matrix[4, 4]f32 {
	return affine_to_view_matrix(camera.transform)
}

get_world_to_clip_matrix :: proc(camera: Camera, width: int, height: int) -> matrix[4, 4]f32 {
	return get_view_to_clip_matrix(camera.projection, width, height) * 
	       get_world_to_view_matrix(camera)
}

@(private="file")
matrix4_perspective_reverse_z_infinite :: proc(fovy, aspect, near: f32) -> matrix[4, 4]f32 {
	tan_half_fovy := math.tan(0.5 * fovy)
	m: matrix[4, 4]f32
	m[0, 0] = 1 / (aspect * tan_half_fovy)
	m[1, 1] = -1 / tan_half_fovy
	m[2, 3] = near
	m[3, 2] = 1
	return m
}

@(private="file")
matrix4_orthographic_reverse_z :: proc(
	left, right, bottom, top, near, far: f32,
) -> matrix[4, 4]f32 {
	m: matrix[4, 4]f32
	m[0, 0] = 2 / (right - left)
	m[0, 3] = -(right + left) / (right - left)
	m[1, 1] = -2 / (top - bottom)
	m[1, 3] = (top + bottom) / (top - bottom)
	m[2, 2] = -1 / (far - near)
	m[2, 3] = far / (far - near)
	m[3, 3] = 1
	return m
}
