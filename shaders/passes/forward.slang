import lib.material;
import lib.surface;
import lib.common;
import lib.brdf;

public struct FragmentInput {
    public float4 clipPosition: SV_Position;
    public float3 worldPosition;
    public float3 worldNormal;
    public float2 texCoords;
    public nointerpolation uint instanceIndex;
}

public float4 ForwardFragment<M: Material>(FragmentInput input) {
    let viewPos = Constants.view.position;
    let instance = Constants.instances[input.instanceIndex];
    let materialOut = M.Sample(instance.materialAddress, MakeSurfaceInput(input));
    let surfaceOut = materialOut._0;
    let brdf = materialOut._1;

    var color = surfaceOut.emission;
    if (M.B.IsLit()) {
        color += brdf.CalculateAmbient(
            surfaceOut, 
            Constants.lighting.GetEnvironment(), 
            normalize(viewPos - input.worldPosition)
        );

        for (uint i = 0; i < Constants.lighting.pointLightCount; i++) {
            let light = Constants.lighting.pointLights[i];
            color += CalculateRadiance(brdf, light, surfaceOut, viewPos); 
        }

        for (uint i = 0; i < Constants.lighting.dirLightCount; i++) {
            let light = Constants.lighting.dirLights[i];
            color += CalculateRadiance(brdf, light, surfaceOut, viewPos); 
        }
    }

    return float4(color, surfaceOut.alpha);
}

SurfaceInput MakeSurfaceInput(FragmentInput input) {
    SurfaceInput s;
    s.viewPosition = Constants.view.position;
    s.position = input.worldPosition;
    s.texCoords = input.texCoords;
    s.geometryNormal = normalize(input.worldNormal);
    s.geometryTangent = float3(0.0);
    s.tangentHandedness = 0.0;
    return s;
}
