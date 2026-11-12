import lib.common;
import lib.mesh;
import passes.forward;
import materials.unlit;
import materials.pbr;

[shader("vertex")]
FragmentInput VSMain(
    uint drawID: SV_DrawIndex,
    uint instanceID: SV_InstanceID, 
    uint vertexID: SV_VertexID
) {
    FragmentInput output;
    var mesh = Constants.draws[drawID].meshRecord;
    var instanceIndex = Constants.draws[drawID].instanceOffset + instanceID;
    var instance = Constants.instances[instanceIndex];

    var vertexPosition = MeshLoadFloat(mesh, vertexID, ATTR_POSITION, float4(0, 0, 0, 1)).xyz;
    var vertexTexCoord = MeshLoadFloat(mesh, vertexID, ATTR_TEX_COORD_0, float4(0)).xy;
    var vertexUnormal = MeshLoadFloat(mesh, vertexID, ATTR_NORMAL, float4(0, 1, 0, 0)).xyz;
    var vertexNormal = normalize(vertexUnormal);

    var worldNormal = mul(float3x3(instance.objectToWorld), vertexNormal);
    var worldPosition = mul(instance.objectToWorld, float4(vertexPosition, 1.0));

    output.clipPosition = mul(Constants.view.worldToClip, float4(worldPosition, 1.0));
    output.worldPosition = worldPosition;
    output.worldNormal = worldNormal;
    output.texCoords = vertexTexCoord;
    output.instanceIndex = instanceIndex;
    return output;
}

static const uint MATERIAL_TYPE_PBR = 0;
static const uint MATERIAL_TYPE_UNLIT = 1;

[shader("fragment")]
float4 FSMain(FragmentInput input): SV_Target {
    switch (Constants.instances[input.instanceIndex].materialType) {
    case MATERIAL_TYPE_UNLIT: 
        return ForwardFragment<UnlitMaterial>(input);
    case MATERIAL_TYPE_PBR:
        return ForwardFragment<PbrMaterial>(input);
    default:
        return float4(1.0, 0.0, 0.0, 1.0);
    }
}

