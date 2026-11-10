package main
import "base:runtime"
import "core:reflect"
import "core:container/handle_map"

Material_Handle :: distinct handle_map.Handle64

Material_Error :: enum {
	None,
	Invalid_Handle,
	Out_Of_Gpu_Memory,
}

Material_Fallback :: enum {
	Default,
	Error,
}

Material :: struct {
	base_color_factor: Maybe([4]f32),
	base_color_texture: Maybe(Texture_Handle),
	sampler: Texture_Sampler,
}

Material_Data :: struct {
	base_color_factor: [4]f32,
	base_color_texture: Texture_Index,
	sampler: Texture_Sampler,
	flags: Material_Flags,
}

Material_Flags :: bit_set[Material_Flag; u32]

Material_Flag :: enum {
	Has_Base_Color_Texture,
}

get_material_fallback :: proc(fallback: Material_Fallback) -> Material {
	switch fallback {
	case .Default:
		return {base_color_factor = {0.8, 0.8, 0.8, 1.0}}
	case .Error:
		return {base_color_factor = {1.0, 0.0, 1.0, 1.0}}
	}
	return {}
}

resolve_material :: proc(textures: ^Textures, params: Material) -> Material_Data {
	flags := Material_Flags{}

	base_color_texture, base_color_ok := params.base_color_texture.?
	base_color_index: Texture_Index
	if base_color_ok {
		base_color_index = textures_get_index(textures, base_color_texture, .Color_Error)
		flags += {.Has_Base_Color_Texture}
	}

	return {
		base_color_factor = params.base_color_factor.? or_else {1.0, 1.0, 1.0, 1.0},
		base_color_texture = base_color_index,
		sampler = params.sampler,
		flags = flags,
	}
}

resolve_texture_dependencies :: proc(out: ^[dynamic]Texture_Handle, value: any) {
    if value.data == nil {
        return
    }

    if value.id == typeid_of(Texture_Handle) {
        handle := (^Texture_Handle)(value.data)^
        if handle != {} {
            append(out, handle)
        }
        return
    }

    #partial switch v in runtime.type_info_base(type_info_of(value.id)).variant {
    case runtime.Type_Info_Union:
        resolve_texture_dependencies(out, reflect.get_union_variant(value))
    case runtime.Type_Info_Struct:
        for i in 0..<reflect.struct_field_count(value.id) {
            field := reflect.struct_field_at(value.id, i)
            resolve_texture_dependencies(out, reflect.struct_field_value(value, field))
        }
    case runtime.Type_Info_Array, runtime.Type_Info_Enumerated_Array,
         runtime.Type_Info_Slice, runtime.Type_Info_Dynamic_Array:
        for i in 0..<reflect.length(value) {
            resolve_texture_dependencies(out, reflect.index(value, i))
        }
    }
}
