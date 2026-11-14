package main
import "base:runtime"
import "core:slice"
import "core:strings"
import vk "vendor:vulkan"

Shader_Program_Id :: distinct u32

Shaders :: struct {
	modules:         [dynamic]Shader_Module,
	modules_by_name: map[string]int,
	programs:        [dynamic]Shader_Program,
	programs_by_key: map[Shader_Program_Key]Shader_Program_Id,
	allocator:       runtime.Allocator,
}

@(private = "file")
Shader_Module :: struct {
	name:   string,
	handle: vk.ShaderModule,
}

@(private = "file")
Shader_Program_Key :: struct {
	module_name: string,
	entry_name:  string,
	stage:       vk.ShaderStageFlag,
}

@(private = "file")
Shader_Program :: struct {
	module_index: int,
	entry_name:   cstring,
	stage:        vk.ShaderStageFlag,
}

shaders_init :: proc(shaders: ^Shaders, allocator := context.allocator) {
	shaders.modules = make([dynamic]Shader_Module, allocator)
	shaders.modules_by_name = make(map[string]int, allocator)
	shaders.programs = make([dynamic]Shader_Program, allocator)
	shaders.programs_by_key = make(map[Shader_Program_Key]Shader_Program_Id, allocator)
	shaders.allocator = allocator
	// Reserve program 0
	append(&shaders.programs, Shader_Program{})
}

shaders_destroy :: proc(shaders: ^Shaders, device: Device) {
	for module in shaders.modules {
		delete(module.name, shaders.allocator)
		if module.handle != 0 {
			vk.DestroyShaderModule(device.logical, module.handle, nil)
		}
	}

	for program in shaders.programs {
		delete(program.entry_name, shaders.allocator)
	}

	for key, _ in shaders.programs_by_key {
		delete(key.entry_name, shaders.allocator)
	}

	delete(shaders.modules)
	delete(shaders.modules_by_name)
	delete(shaders.programs)
	delete(shaders.programs_by_key)
	shaders^ = {}
}

@(require_results)
shaders_load_module :: proc(
	shaders: ^Shaders,
	device: Device,
	name: string,
	spirv: []u32,
) -> vk.Result {
	new_module: vk.ShaderModule
	new_module_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = slice.size(spirv),
		pCode    = raw_data(spirv),
	}
	vk.CreateShaderModule(device.logical, &new_module_info, nil, &new_module) or_return

	if module_index, exists := shaders.modules_by_name[name]; exists {
		module := &shaders.modules[module_index]
		if module.handle != 0 {
			vk.DestroyShaderModule(device.logical, module.handle, nil)
		}
		module.handle = new_module
	} else {
		module_index = len(shaders.modules)
		module_name := strings.clone(name, shaders.allocator)
		append(&shaders.modules, {name = module_name, handle = new_module})
		shaders.modules_by_name[module_name] = module_index
	}
	return .SUCCESS
}

@(require_results)
shaders_get_program :: proc(
	shaders: ^Shaders,
	module: string,
	entry: string,
	stage: vk.ShaderStageFlag,
) -> (
	Shader_Program_Id,
	bool,
) {
	if program_id, ok := shaders.programs_by_key[{module, entry, stage}]; ok {
		return program_id, true
	}

	module_index, ok := shaders.modules_by_name[module]
	if !ok {
		return {}, false
	}

	program_id := Shader_Program_Id(len(shaders.programs))
	entry_name := strings.clone(entry, shaders.allocator)
	entry_cname := strings.clone_to_cstring(entry, shaders.allocator)
	program_key := Shader_Program_Key {
		module_name = shaders.modules[module_index].name,
		entry_name  = entry_name,
		stage       = stage,
	}
	append(
		&shaders.programs,
		{module_index = module_index, entry_name = entry_cname, stage = stage},
	)
	shaders.programs_by_key[program_key] = program_id
	return program_id, true
}

@(require_results)
shaders_get_stage_info :: proc(
	shaders: Shaders,
	id: Shader_Program_Id,
) -> vk.PipelineShaderStageCreateInfo {
	assert(int(id) != 0)
	assert(int(id) < len(shaders.programs))

	program := shaders.programs[id]
	return {
		sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage = {program.stage},
		pName = program.entry_name,
		module = shaders.modules[program.module_index].handle,
	}
}
