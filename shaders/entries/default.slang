import lib.common;
import lib.vertex;
import passes.forward;
import materials.unlit;
import materials.lambert;

[shader("vertex")]
FragmentInput VSMain(
    uint drawID: SV_DrawIndex,
    uint instanceID: SV_InstanceID, 
    uint vertexID: SV_VertexID
) {
    return ForwardVertex(drawID, instanceID, vertexID);
}

static const uint MATERIAL_TYPE_LAMBERT = 0;
static const uint MATERIAL_TYPE_UNLIT = 1;

[shader("fragment")]
float4 FSMain(FragmentInput input): SV_Target {
    switch (Constants.instances[input.instanceIndex].materialType) {
    case MATERIAL_TYPE_UNLIT: 
        return ForwardFragment<UnlitMaterial>(input);
    case MATERIAL_TYPE_LAMBERT:
        return ForwardFragment<LambertMaterial>(input);
    default:
        return float4(1.0, 0.0, 0.0, 1.0);
    }
}

