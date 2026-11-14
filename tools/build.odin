package build

import "core:flags"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

SHADER_SRC :: "shaders"
SHADER_ENTRIES :: "shaders/entries"
SHADER_OUT :: "shaders/compiled"
BUILD_OUT :: "build"
PROGRAM_NAME :: "render"

VMA_DIR :: "third_party/vma"
VMA_VK_VERSION :: "3"
VMA_PREMAKE_ACTION_WINDOWS :: "vs2022"

Toggle :: enum {
	auto,
	on,
	off,
}

Options :: struct {
	release:         bool `usage:"Optimized build (-o:speed) instead of a debug build."`,
	validation:      Toggle `usage:"Vulkan validation layer: auto (on in debug), on, off."`,
	sync_validation: Toggle `usage:"Synchronization validation: auto (on in debug), on, off."`,
}

main :: proc() {
	options: Options
	flags.parse_or_exit(&options, os.args, .Odin)

	build_vma()
	compile_shaders()
	build_program(options)
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

	files, err := os.read_all_directory_by_path(SHADER_ENTRIES, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("Failed to read directory '%s': %v", SHADER_ENTRIES, err)
		return
	}

	// Any module anywhere under shaders/ may be imported by any entry, so a change
	// to one of them rebuilds every entry. Coarse, but never stale.
	modules_time := newest_modification_time(SHADER_SRC)

	for file in files {
		if file.type == .Directory || filepath.ext(file.name) != ".slang" {
			continue
		}

		src := fmt.tprintf("%s/%s", SHADER_ENTRIES, file.name)
		dst := fmt.tprintf("%s/%s.spv", SHADER_OUT, filepath.stem(file.name))

		if !needs_rebuild(src, dst, modules_time) {
			continue
		}

		fmt.eprintfln("Compiling %s", src)

		run(
			{
				"slangc",
				src,
				"-I",
				SHADER_SRC,
				"-target",
				"spirv",
				"-profile",
				"spirv_1_4",
				"-emit-spirv-directly",
				"-fvk-use-scalar-layout",
				"-fvk-use-entrypoint-name",
				"-matrix-layout-column-major",
				"-o",
				dst,
			},
		)
	}
}

build_program :: proc(options: Options) {
	mode := "release" if options.release else "debug"
	out_dir := fmt.tprintf("%s/%s", BUILD_OUT, mode)
	_ = os.make_directory_all(out_dir)

	args := make([dynamic]string, context.temp_allocator)
	append(&args, "odin", "build", ".")
	append(&args, "-o:speed" if options.release else "-debug")
	append_toggle_define(&args, "ENABLE_VALIDATION", options.validation)
	append_toggle_define(&args, "ENABLE_SYNC_VALIDATION", options.sync_validation)
	append(&args, "-vet", "-strict-style", "-disallow-do", "-warnings-as-errors")
	append(&args, fmt.tprintf("-out:%s/%s", out_dir, PROGRAM_NAME))

	fmt.eprintfln(
		"Building %s (%s, validation: %v, sync validation: %v)",
		PROGRAM_NAME,
		mode,
		options.validation,
		options.sync_validation,
	)
	run(args[:])
}

append_toggle_define :: proc(args: ^[dynamic]string, name: string, toggle: Toggle) {
	switch toggle {
	case .auto:
	case .on:
		append(args, fmt.tprintf("-define:%s=true", name))
	case .off:
		append(args, fmt.tprintf("-define:%s=false", name))
	}
}

newest_modification_time :: proc(dir: string) -> (newest: time.Time) {
	files, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return
	}
	for file in files {
		path := fmt.tprintf("%s/%s", dir, file.name)

		if file.type == .Directory {
			if t := newest_modification_time(path); time.diff(newest, t) > 0 {
				newest = t
			}
			continue
		}

		if filepath.ext(file.name) != ".slang" {
			continue
		}
		if t, terr := os.modification_time_by_path(path); terr == nil && time.diff(newest, t) > 0 {
			newest = t
		}
	}
	return
}

needs_rebuild :: proc(src, dst: string, deps_time: time.Time) -> bool {
	src_time, err1 := os.modification_time_by_path(src)
	dst_time, err2 := os.modification_time_by_path(dst)
	if err1 != nil || err2 != nil {
		return true
	}
	return time.diff(dst_time, src_time) > 0 || time.diff(dst_time, deps_time) > 0
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
