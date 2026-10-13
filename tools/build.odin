package build 

import "core:os"
import "core:fmt"
import "core:strings"
import "core:path/filepath"
import "core:time"

SHADER_SRC :: "shaders"
SHADER_OUT :: "shaders/compiled"
BUILD_OUT :: "build"
PROGRAM_NAME :: "render"

VMA_DIR :: "third_party/vma"
VMA_VK_VERSION :: "3"
VMA_PREMAKE_ACTION_WINDOWS :: "vs2022"

main :: proc() {
	build_vma()
	compile_shaders()
	build_program()
}

build_vma :: proc() {
	if vma_is_built() {
		return
	}

	fmt.eprintln("Building VMA")

	vk_version_arg := fmt.tprintf("--vk-version=%s", VMA_VK_VERSION)

	when ODIN_OS == .Windows {
		// Needs the MSVC toolchain on PATH, so run this from a shell with vcvars64 loaded.
		run({"premake5", vk_version_arg, VMA_PREMAKE_ACTION_WINDOWS}, VMA_DIR)
		run({"cmd", "/c", "build.bat"}, fmt.tprintf("%s/build", VMA_DIR))
	} else {
		platform, config: string
		when ODIN_OS == .Darwin {
			platform = "macosx"
			config = "release_arm64" if ODIN_ARCH == .arm64 else "release_x86_64"
		} else {
			platform = "linux"
			config = "release_x86_64"
		}

		run({"premake5", vk_version_arg, "gmake"}, VMA_DIR)
		run(
			{"make", fmt.tprintf("config=%s", config)},
			fmt.tprintf("%s/build/make/%s", VMA_DIR, platform),
		)
	}

	if !vma_is_built() {
		fmt.eprintfln("VMA build finished but no library was found in '%s'", VMA_DIR)
		os.exit(1)
	}
}

vma_is_built :: proc() -> bool {
	files, err := os.read_all_directory_by_path(VMA_DIR, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("Failed to read directory '%s': %v", VMA_DIR, err)
		os.exit(1)
	}

	for file in files {
		ext := filepath.ext(file.name)
		if (strings.has_prefix(file.name, "vma_") && ext == ".a") || 
		   (strings.has_prefix(file.name, "libvma_") && ext == ".a") ||
		   (strings.has_prefix(file.name, "vma_") && ext == ".lib") {
			return true
		}
	}
	return false
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
	run({"odin", "build", ".", "-debug", "-vet", "-strict-style", "-disallow-do", "-warnings-as-errors", out_arg})
}

needs_rebuild :: proc(src, dst: string) -> bool {
	src_time, err1 := os.modification_time_by_path(src)
	dst_time, err2 := os.modification_time_by_path(dst)
	if err1 != nil || err2 != nil {
		return true
	}
	return time.diff(dst_time, src_time) > 0
}

run :: proc(command: []string, working_dir := "") {
	state, _, stderr, err := os.process_exec(
		{command = command, working_dir = working_dir},
		context.temp_allocator,
	)
	if err != nil {
		fmt.eprintfln("Failed to launch '%s': %v", command[0], err)
		os.exit(1)
	}
	if state.exit_code != 0 {
		fmt.eprintfln("'%s' failed: %s", command[0], string(stderr))
		os.exit(state.exit_code)
	}
}

