package main
import "core:log"
import "core:math"
import "core:os"
import "core:time"
import "core:math/linalg"
import "core:mem"
import "core:fmt"

Controls :: struct {
	walk_forward: Key,
	walk_backward: Key,
	walk_right: Key,
	walk_left: Key,
	go_up: Key,
	go_down: Key,
	boost: Key,
	zoom_amount: f32,
	mouse_sensitivity: f32,
}

Fly_Camera :: struct {
	position: [3]f32,
	velocity: [3]f32,
	yaw, pitch: f32,

	base_fov_radians: f32,
	target_zoom: f32,
	zoom: f32,

	damp: f32,
	boost: f32,
	speed: f32,
	zoom_speed: f32,
}

main :: proc() {
	context.logger = log.create_console_logger(opt={.Level, .Terminal_Color})
	defer log.destroy_console_logger(context.logger)

	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)

		defer {
			if len(track.allocation_map) > 0 {
				fmt.eprintf("=== %v allocations not freed ===\n", len(track.allocation_map))
				for _, entry in track.allocation_map {
					fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
				}
			}
			if len(track.bad_free_array) > 0 {
				fmt.eprintf("=== %v incorrect frees ===\n", len(track.bad_free_array))
				for entry in track.bad_free_array {
					fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
				}
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

	window, err := window_create(1280, 720, "window")
	if err != nil {
		os.exit(1)
	}

	renderer: Renderer
	if err := renderer_init(&renderer, window); err != nil {
		os.exit(1)
	}

	window_set_cursor_state(window, .Disabled)
	controls := default_controls()
	flycam := default_flycam()
	scene := Scene {
		camera = {
			transform = AFFINE_IDENTITY,
			projection = Perspective_Projection {
				near = 0.001,
				far = 1000.0,
			},
		},
		ambient_light = {
			illuminance = 1.0,
			color = {0.2, 0.7, 1.0},
		},
	}

	append(&scene.directional_lights, {
		direction = {0.4, -1.0, 0.2},
		color = {1.0, 1.0, 1.0},
		illuminance = 2.0,
	})

	append(&scene.point_lights, {
		position = {0.0, 0.0, 0.0},
		color = {1.0, 1.0, 0.5},
		power = 100.0,
	})

	current_time := time.tick_now()
	for !window_should_close(window) {
		delta_time := f32(time.duration_seconds(time.tick_since(current_time)))
		current_time = time.tick_now()

		poll_window_events(window)

		cursor_state := window_get_cursor_state(window)
		if (.Just_Pressed in get_mouse_button(window, .Left) && cursor_state == .Normal) ||
		    .Just_Pressed in get_key(window, .Escape) {
 			#partial switch cursor_state {
			case .Normal: cursor_state = .Disabled
			case .Disabled: cursor_state = .Normal
			case: cursor_state = .Disabled
			}
			window_set_cursor_state(window, cursor_state)
		} 

		if cursor_state == .Disabled {
			look_around(&flycam, window, controls)
			walk_around(&flycam, window, controls, delta_time)
			zoom(&flycam, window, controls)
			update_flycam(&flycam, delta_time)
		}

		update_camera(&scene.camera, flycam)

		if err := renderer_draw(&renderer, scene); err != nil {
			log.errorf("Renderer draw error: %v", err)
			os.exit(1)
		}

		free_all(context.temp_allocator)
	}

	renderer_destroy(&renderer)
	window_destroy(window)
}

look_around :: proc(flycam: ^Fly_Camera, window: ^Window, controls: Controls) {
	flycam.yaw += f32(window.cursor_delta.x) * controls.mouse_sensitivity
	flycam.pitch += f32(window.cursor_delta.y)  * controls.mouse_sensitivity
	flycam.pitch = clamp(flycam.pitch, -1.56, 1.56)
}

walk_around :: proc(flycam: ^Fly_Camera, window: ^Window, controls: Controls, dt: f32) {
	right := [3]f32 {math.cos(flycam.yaw), 0.0, -math.sin(flycam.yaw)}
	front := [3]f32 {math.sin(flycam.yaw), 0.0, math.cos(flycam.yaw)}

	wish := [3]f32{0.0, 0.0, 0.0}
	if .Pressed in get_key(window, controls.walk_forward) {
		wish += front
	}
	if .Pressed in get_key(window, controls.walk_backward) {
		wish -= front
	}
	if .Pressed in get_key(window, controls.walk_left) {
		wish -= right
	}
	if .Pressed in get_key(window, controls.walk_right) {
		wish += right
	}
	if .Pressed in get_key(window, controls.go_up) {
		wish.y += 1.0
	}
	if .Pressed in get_key(window, controls.go_down) {
		wish.y -= 1.0
	}

	wish = linalg.normalize0(wish)
	speed := flycam.speed
	if .Pressed in get_key(window, controls.boost) {
		speed *= flycam.boost
	}

	flycam.velocity += (wish * speed - flycam.velocity) * (1 - math.exp(-flycam.damp * dt))
}

zoom :: proc(flycam: ^Fly_Camera, window: ^Window, controls: Controls) {
	flycam.target_zoom += controls.zoom_amount * f32(window.scroll_delta.y)
}

update_flycam :: proc(flycam: ^Fly_Camera, dt: f32) {
	flycam.position += flycam.velocity * dt
	flycam.zoom = linalg.lerp(flycam.zoom, flycam.target_zoom, min(flycam.zoom_speed * dt, 1.0))
}

update_camera :: proc(camera: ^Camera, flycam: Fly_Camera) {
	camera.transform.translation = flycam.position
	camera.transform.rotation = linalg.quaternion_from_euler_angles(flycam.yaw, flycam.pitch, 0.0, .YXZ)
	switch &p in camera.projection {
	case Orthographic_Projection:
	case Perspective_Projection:
		fov := 2 * math.atan(math.tan(flycam.base_fov_radians * 0.5) / math.exp(flycam.zoom))
		max_fov := math.to_radians_f32(140.0)
		p.fov_radians = min(fov, max_fov)
	}
}

default_flycam :: proc() -> Fly_Camera {
	return { 
		base_fov_radians = math.to_radians_f32(90.0),
		zoom_speed = 10.0,
		boost = 1.5,
		speed = 4.0,
		damp = 15.0,
	}
}

default_controls :: proc() -> Controls {
	return {
		walk_forward = .W,
		walk_backward = .S,
		walk_left = .A,
		walk_right = .D,
		go_up = .Space,
		go_down = .Left_Control,
		boost = .Left_Shift,
		zoom_amount = 0.1,
		mouse_sensitivity = 0.002,
	}
}
