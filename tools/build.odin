package build 

import "core:os"
import "core:fmt"
import "core:path/filepath"
import "core:time"

SHADER_SRC :: "shaders"
SHADER_OUT :: "shaders/compiled"
BUILD_OUT :: "build"
PROGRAM_NAME :: "render"

main :: proc() {
	compile_shaders()
	build_program()
}

compile_shaders :: proc() {
	_ = os.make_directory_all(SHADER_OUT)

	files, err := os.read_all_directory_by_path(SHADER_SRC, context.temp_allocator)
	if err != nil { 
		fmt.eprintfln("Failed to read directory '%s': %v", SHADER_SRC, err)
	}

	for file in files {
		if filepath.ext(file.name) != ".slang" {
			continue
		}

		src := fmt.tprintf("%s/%s", SHADER_SRC, file.name)
		dst := fmt.tprintf("%s/%s.spv", SHADER_OUT, filepath.stem(file.name))

		if !needs_rebuild(src, dst) {
			continue
		}

		fmt.eprintfln("Compiling %s", src)	

		run({
			"slangc", src,
			"-target", "spirv",
			"-profile", "spirv_1_4",
			"-emit-spirv-directly",
			"-fvk-use-entrypoint-name",
			"-o", dst,
		})
	}
}

build_program :: proc() {
	_ = os.make_directory_all(BUILD_OUT)
	out_arg := fmt.tprintf("-out:\"%s/%s\"", BUILD_OUT, PROGRAM_NAME)
	run({"odin", "build", ".", "-debug", "-vet", "-strict-style", "-vet-tabs", "-disallow-do", "-warnings-as-errors", out_arg})
}

run :: proc(command: []string) {
	state, _, stderr, err := os.process_exec({command = command}, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("Failed to launch '%s': %v", command[0], err)
		os.exit(1)
	}
	if state.exit_code != 0 {
		fmt.eprintfln("'%s' failed: %s", command[0], string(stderr))
		os.exit(state.exit_code)
	}
}

needs_rebuild :: proc(src, dst: string) -> bool {
	src_time, err1 := os.modification_time_by_path(src)
	dst_time, err2 := os.modification_time_by_path(dst)
	if err1 != nil || err2 != nil {
		return true
	}
	return time.diff(dst_time, src_time) > 0
}
