package main
import "base:runtime"
import "core:log"

Passes :: struct {
	ctx:       Pass_Context,
	kinds:     [dynamic]Pass_Kind,
	table:     [dynamic][dynamic]Maybe(Graphics_Pipeline_Id),
	allocator: runtime.Allocator,
}

Pass_Kind_Id :: distinct u32

Pass_Select_Proc :: #type proc(
	shaders: ^Shaders,
	props: Material_Properties,
	base: Raster_State,
	type_name: string,
) -> Maybe(Pass_Selection)

Pass_Kind :: struct {
	name:       string,
	target:     Graphics_Target_Id,
	base_state: Raster_State,
	select:     Pass_Select_Proc,
}

Pass_Selection :: struct {
	vertex:       Shader_Program_Id,
	fragment:     Maybe(Shader_Program_Id),
	raster_state: Raster_State,
}

Pass_Context :: struct {
	shaders:   ^Shaders,
	pipelines: ^Pipelines,
	materials: ^Materials,
}

passes_init :: proc(
	passes: ^Passes,
	shaders: ^Shaders,
	pipelines: ^Pipelines,
	materials: ^Materials,
	allocator := context.allocator,
) {
	passes.kinds = make([dynamic]Pass_Kind, allocator)
	passes.table = make([dynamic][dynamic]Maybe(Graphics_Pipeline_Id), allocator)
	passes.ctx = {shaders, pipelines, materials}
}

passes_destroy :: proc(passes: ^Passes) {
	for row in passes.table {
		delete(row)
	}
	delete(passes.table)
	delete(passes.kinds)
}

passes_add_kind :: proc(passes: ^Passes, device: Device, kind: Pass_Kind) -> Pass_Kind_Id {
	kind_id := Pass_Kind_Id(len(passes.kinds))
	append(&passes.kinds, kind)

	columns := materials_get_variant_count(passes.ctx.materials^)
	row := make([dynamic]Maybe(Graphics_Pipeline_Id), columns, passes.allocator)
	for &entry, variant in row {
		entry = select_pipeline(passes, device, kind_id, Material_Variant_Id(variant))
	}
	append(&passes.table, row)
	return kind_id
}

passes_add_variant :: proc(passes: ^Passes, device: Device, variant: Material_Variant_Id) {
	for &row, kind in passes.table {
		assert(int(variant) == len(row), "Variants must be added in order")
		append(&row, select_pipeline(passes, device, Pass_Kind_Id(kind), variant))
	}
}

passes_get_pipeline :: proc(
	passes: Passes,
	kind: Pass_Kind_Id,
	variant: Material_Variant_Id,
) -> Maybe(Graphics_Pipeline_Id) {
	return passes.table[kind][variant]
}

@(private = "file")
select_pipeline :: proc(
	passes: ^Passes,
	device: Device,
	kind_id: Pass_Kind_Id,
	variant_id: Material_Variant_Id,
) -> Maybe(Graphics_Pipeline_Id) {
	kind := passes.kinds[kind_id]
	shaders := passes.ctx.shaders
	pipelines := passes.ctx.pipelines
	materials := passes.ctx.materials
	variant := materials_get_variant(materials^, variant_id)
	type_name := materials_get_type_name(materials^, variant.type)
	selection, ok := kind.select(shaders, variant.props, kind.base_state, type_name).?
	if !ok {
		return nil
	}

	pipeline_id, result := pipelines_get_or_add(
		pipelines,
		device,
		shaders^,
		{
			target = kind.target,
			vertex = selection.vertex,
			fragment = selection.fragment,
			raster_state = selection.raster_state,
		},
	)
	if result != .SUCCESS {
		log.errorf(
			"Pass '%s': pipeline for material type '%s' failed: %v",
			kind.name,
			type_name,
			result,
		)
		return nil
	}
	return pipeline_id
}
