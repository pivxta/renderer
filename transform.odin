package main
import "core:math/linalg"

AFFINE_IDENTITY :: Affine_Transform{scale = 1, rotation = 1} // rotation = 1 is the identity quaternion (w = 1)
AXIS_RIGHT   :: [3]f32{1, 0, 0}
AXIS_UP      :: [3]f32{0, 1, 0}
AXIS_FORWARD :: [3]f32{0, 0, 1}

Affine_Transform :: struct {
	scale: f32,
	rotation: quaternion128,
	translation: [3]f32,
}

affine_right :: proc(t: Affine_Transform) -> [3]f32 {
	return linalg.quaternion_mul_vector3(t.rotation, AXIS_RIGHT)
}

affine_up :: proc(t: Affine_Transform) -> [3]f32 {
	return linalg.quaternion_mul_vector3(t.rotation, AXIS_UP)
}

affine_forward :: proc(t: Affine_Transform) -> [3]f32 {
	return linalg.quaternion_mul_vector3(t.rotation, AXIS_FORWARD)
}

affine_left :: proc(t: Affine_Transform) -> [3]f32 {
	return -affine_right(t)
}

affine_down :: proc(t: Affine_Transform) -> [3]f32 {
	return -affine_up(t)
}

affine_backward :: proc(t: Affine_Transform) -> [3]f32 {
	return -affine_forward(t)
}

affine_axes :: proc(t: Affine_Transform) -> (right, up, forward: [3]f32) {
	return affine_right(t), affine_up(t), affine_forward(t)
}

affine_make :: proc(
	translation := [3]f32{},
	rotation := quaternion128(1),
	scale: f32 = 1,
) -> Affine_Transform {
	return {scale = scale, rotation = rotation, translation = translation}
}

affine_look_at :: proc(eye, target: [3]f32, up := [3]f32{0, 1, 0}) -> Affine_Transform {
	return {
		scale       = 1,
		rotation    = conj(linalg.quaternion_look_at(eye, target, up)),
		translation = eye,
	}
}

affine_mul :: proc(a, b: Affine_Transform) -> Affine_Transform {
	return {
		scale       = a.scale * b.scale,
		rotation    = a.rotation * b.rotation,
		translation = a.translation + a.scale * linalg.quaternion_mul_vector3(a.rotation, b.translation),
	}
}

affine_inverse :: proc(t: Affine_Transform) -> Affine_Transform {
	inv_scale := 1 / t.scale
	inv_rotation := conj(t.rotation)
	return {
		scale       = inv_scale,
		rotation    = inv_rotation,
		translation = -inv_scale * linalg.quaternion_mul_vector3(inv_rotation, t.translation),
	}
}

affine_transform_point :: proc(t: Affine_Transform, p: [3]f32) -> [3]f32 {
	return linalg.quaternion_mul_vector3(t.rotation, p * t.scale) + t.translation
}

affine_transform_vector :: proc(t: Affine_Transform, v: [3]f32) -> [3]f32 {
	return linalg.quaternion_mul_vector3(t.rotation, v * t.scale)
}

affine_to_matrix3x4 :: proc(t: Affine_Transform) -> matrix[3, 4]f32 {
	full := affine_to_matrix(t)

	m: matrix[3, 4]f32
	for row in 0..<3 {
		for col in 0..<4 {
			m[row, col] = full[row, col]
		}
	}

	return m
}

affine_to_matrix :: proc(t: Affine_Transform) -> matrix[4, 4]f32 {
	return linalg.matrix4_from_trs(t.translation, t.rotation, {t.scale, t.scale, t.scale})
}

affine_to_view_matrix :: proc(camera: Affine_Transform) -> matrix[4, 4]f32 {
	return affine_to_matrix(affine_inverse(camera))
}

affine_lerp :: proc(a, b: Affine_Transform, t: f32) -> Affine_Transform {
	return {
		scale       = a.scale + (b.scale - a.scale) * t,
		rotation    = linalg.quaternion_slerp(a.rotation, b.rotation, t),
		translation = a.translation + (b.translation - a.translation) * t,
	}
}

affine_normalized :: proc(t: Affine_Transform) -> Affine_Transform {
	result := t
	result.rotation = linalg.quaternion_normalize(t.rotation)
	return result
}
