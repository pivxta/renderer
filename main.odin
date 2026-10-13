package main
import "core:log"
import "vendor:glfw"

main :: proc() {
	context.logger = log.create_console_logger(opt={.Level, .Terminal_Color})
	defer log.destroy_console_logger(context.logger)
	
	glfw.Init()
	defer glfw.Terminate()

	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	window := glfw.CreateWindow(800, 600, "Hello, world!", nil, nil)
	if window == nil {
		log.panic("Failed to create window") 
	}
	defer glfw.DestroyWindow(window)

	renderer: Renderer
	renderer_init(&renderer, window)

	for !glfw.WindowShouldClose(window) {
		glfw.PollEvents()
		renderer_draw(&renderer)
	}

	renderer_destroy(&renderer)
}
