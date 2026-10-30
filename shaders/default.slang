static const float PI = 3.1415926535;

interface Light {
    float3 get_incident_radiance(float3 position);
    float3 get_omega_i(float3 position);
}

struct View {
    float4x4 world_to_clip;
}

struct Instance {
    float3x4 object_to_world;
}

struct Vertex {
    float3 position;
    float3 normal;
    float2 tex_coords;
}

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
    ImmutablePtr<PointLight> point_lights;
    uint point_light_count;
    ImmutablePtr<DirLight> dir_lights;
    uint dir_light_count;
}

struct PushConstants {
    ImmutablePtr<View> view;
    ImmutablePtr<Instance> instances;
    ImmutablePtr<Vertex> vertices;
    ImmutablePtr<Lighting> lighting;
}

struct VertexOutput {
    float4 clip_position: SV_Position;
    float3 world_position;
    float3 world_normal;
    float2 tex_coords;
}

[[vk::push_constant]] ConstantBuffer<PushConstants> constants;

[shader("vertex")]
VertexOutput vertex_main(uint instance_id: SV_InstanceID, uint vertex_id: SV_VertexID) {
    VertexOutput output;
    Instance instance = constants.instances[instance_id];
    Vertex vertex = constants.vertices[vertex_id];

    var world_normal = mul(float3x3(instance.object_to_world), vertex.normal);
    var world_position = mul(instance.object_to_world, float4(vertex.position, 1.0));
    output.clip_position = mul(constants.view.world_to_clip, float4(world_position, 1.0));
    output.world_position = world_position;
    output.world_normal = world_normal;
    output.tex_coords = vertex.tex_coords;
    return output;
}

[[vk::binding(0, 0)]]
Sampler2D[] samplers;

[shader("fragment")]
float4 fragment_main(VertexOutput input): SV_Target {
    let albedo = samplers[0].Sample(input.tex_coords).rgb;
    let normal = normalize(input.world_normal);
    
    var color = albedo 
        * constants.lighting.ambient_color 
        * constants.lighting.ambient_illuminance;

    for (uint i = 0; i < constants.lighting.point_light_count; i++) {
        let light = constants.lighting.point_lights[i];
        let incident_radiance = light.get_incident_radiance(input.world_position);
        let omega_i = light.get_omega_i(input.world_position);
        color += incident_radiance * albedo * max(dot(omega_i, normal), 0.0) / PI; 
    }

    for (uint i = 0; i < constants.lighting.dir_light_count; i++) {
        let light = constants.lighting.dir_lights[i];
        let incident_radiance = light.get_incident_radiance(input.world_position);
        let omega_i = light.get_omega_i(input.world_position);
        color += incident_radiance * albedo * max(dot(omega_i, normal), 0.0) / PI; 
    }

    return float4(color, 1.0);
}

