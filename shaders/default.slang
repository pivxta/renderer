import lib.mesh;

static const float PI = 3.1415926535;

interface Light {
    float3 get_incident_radiance(float3 position);
    float3 get_omega_i(float3 position);
}

struct View {
    float4x4 world_to_clip;
}

struct Instance {
    float3x4  object_to_world;
    uint64_t  material_address;
    uint      material_type;
}

struct Draw {
    MeshRecord* mesh_record; 
    uint instance_offset; 
} 

static const uint MATERIAL_TYPE_PBR = 0;
static const uint MATERIAL_TYPE_UNLIT = 1;

struct PbrMaterial {
    float4 base_color_factor;
    uint base_color_index;
    uint sampler_index;
    uint flags;
}

static const uint PBR_MATERIAL_HAS_BASE_COLOR_TEXTURE = 1 << 0;

struct UnlitMaterial {
    float4 color_factor;
    uint color_index;
    uint sampler_index;
    uint flags;
}

static const uint UNLIT_MATERIAL_HAS_COLOR_TEXTURE = 1 << 0;

struct PointLight: Light {
    float3 position;
    float radius;
    float power;
    float3 color;

    float3 get_incident_radiance(float3 position) {
        var to_light = this.position - position;
        var distance_sq = dot(to_light, to_light);
        return (this.power * this.color) / max(4.0 * PI * distance_sq, 0.0001);
    }

    float3 get_omega_i(float3 position) {
        return normalize(this.position - position);
    }
}

struct DirLight: Light {
    float3 direction;
    float illuminance;
    float3 color;

    float3 get_incident_radiance(float3 position) {
        return this.illuminance * this.color;
    }

    float3 get_omega_i(float3 position) {
        return normalize(-this.direction);
    }
}

struct Lighting {
    float ambient_illuminance;
    float3 ambient_color;
    PointLight* point_lights;
    uint point_light_count;
    DirLight* dir_lights;
    uint dir_light_count;
}

struct PushConstants {
    View* view;
    Draw* draws;
    Instance* instances;
    Lighting* lighting;
}

struct VertexOutput {
    float4 clip_position: SV_Position;
    float3 world_position;
    float3 world_normal;
    float2 tex_coords;
    nointerpolation uint instance_index;
}

[[vk::push_constant]] ConstantBuffer<PushConstants> constants;

[shader("vertex")]
VertexOutput vertex_main(
    uint draw_id: SV_DrawIndex,
    uint instance_id: SV_InstanceID, 
    uint vertex_id: SV_VertexID
) {
    VertexOutput output;
    var mesh = constants.draws[draw_id].mesh_record;
    var instance_index = constants.draws[draw_id].instance_offset + instance_id;
    var instance = constants.instances[instance_index];

    var vertex_position = mesh_load_float(mesh, vertex_id, ATTR_POSITION, float4(0, 0, 0, 1)).xyz;
    var vertex_tex_coord = mesh_load_float(mesh, vertex_id, ATTR_TEX_COORD_0, float4(0)).xy;
    var vertex_unormal = mesh_load_float(mesh, vertex_id, ATTR_NORMAL, float4(0, 1, 0, 0)).xyz;
    var vertex_normal = normalize(vertex_unormal);

    var world_normal = mul(float3x3(instance.object_to_world), vertex_normal);
    var world_position = mul(instance.object_to_world, float4(vertex_position, 1.0));

    output.clip_position = mul(constants.view.world_to_clip, float4(world_position, 1.0));
    output.world_position = world_position;
    output.world_normal = world_normal;
    output.tex_coords = vertex_tex_coord;
    output.instance_index = instance_index;
    return output;
}

[[vk::binding(0, 0)]]
SamplerState[] samplers;

[[vk::binding(0, 1)]]
Texture2D[] textures;

float4 pbr(
    PbrMaterial *material, 
    float3 world_position,
    float3 world_normal,
    float2 tex_coords
) {
    var sampler = samplers[NonUniformResourceIndex(material.sampler_index)];
    var albedo = material.base_color_factor.rgb;
    if ((material.flags & PBR_MATERIAL_HAS_BASE_COLOR_TEXTURE) != 0) {
        var texture = textures[NonUniformResourceIndex(material.base_color_index)];
        albedo *= texture.Sample(sampler, tex_coords).rgb;
    }
    
    let normal = normalize(world_normal);
    
    var color = albedo / PI
        * constants.lighting.ambient_color 
        * constants.lighting.ambient_illuminance;

    for (uint i = 0; i < constants.lighting.point_light_count; i++) {
        let light = constants.lighting.point_lights[i];
        let incident_radiance = light.get_incident_radiance(world_position);
        let omega_i = light.get_omega_i(world_position);
        color += incident_radiance * albedo * max(dot(omega_i, normal), 0.0) / PI; 
    }

    for (uint i = 0; i < constants.lighting.dir_light_count; i++) {
        let light = constants.lighting.dir_lights[i];
        let incident_radiance = light.get_incident_radiance(world_position);
        let omega_i = light.get_omega_i(world_position);
        color += incident_radiance * albedo * max(dot(omega_i, normal), 0.0) / PI; 
    }

    return float4(color, 1.0);
}

float4 unlit(
    UnlitMaterial *material, 
    float3 world_position,
    float3 world_normal,
    float2 tex_coords
) {
    var sampler = samplers[NonUniformResourceIndex(material.sampler_index)];
    var color = material.color_factor.rgb;
    if ((material.flags & UNLIT_MATERIAL_HAS_COLOR_TEXTURE) != 0) {
        var texture = textures[NonUniformResourceIndex(material.color_index)];
        color *= texture.Sample(sampler, tex_coords).rgb;
    }
    return float4(color, 1.0);
}

[shader("fragment")]
float4 fragment_main(VertexOutput input): SV_Target {
    var material_type = constants.instances[input.instance_index].material_type;
    var material_address = constants.instances[input.instance_index].material_address;
    switch (material_type) {
    case MATERIAL_TYPE_UNLIT: 
        return unlit(
            (UnlitMaterial*)material_address,
            input.world_position,
            input.world_normal,
            input.tex_coords
        );
    case MATERIAL_TYPE_PBR:
        return pbr(
            (PbrMaterial*)material_address,
            input.world_position,
            input.world_normal,
            input.tex_coords,
        );
    default:
        return float4(1.0, 0.0, 0.0, 1.0);
    }
}

