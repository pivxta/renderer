struct View {
    float4x4 world_to_clip;
}

struct Instance {
    float3x4 object_to_world;
}

struct Vertex {
    float3 position;
    float2 tex_coords;
}

struct PushConstants {
    ImmutablePtr<View> view;
    ImmutablePtr<Instance> instances;
    ImmutablePtr<Vertex> vertices;
}

struct VertexOutput {
    float4 clip_position: SV_Position;
    float3 world_position;
    float2 tex_coords;
}

[[vk::push_constant]] ConstantBuffer<PushConstants> constants;

[shader("vertex")]
VertexOutput vertex_main(uint instance_id: SV_InstanceID, uint vertex_id: SV_VertexID) {
    VertexOutput output;
    Instance instance = constants.instances[instance_id];
    Vertex vertex = constants.vertices[vertex_id];

    var world_position = mul(instance.object_to_world, float4(vertex.position, 1.0));
    output.clip_position = mul(constants.view.world_to_clip, float4(world_position, 1.0));
    output.world_position = world_position;
    output.tex_coords = vertex.tex_coords;
    return output;
}

[[vk::binding(0, 0)]]
Sampler2D[] samplers;

[shader("fragment")]
float4 fragment_main(VertexOutput input): SV_Target {
    return float4(samplers[0].Sample(input.tex_coords).rgb, 1.0);
}

