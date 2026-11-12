public struct SurfaceInput {
    public float3 viewPosition;
    public float3 position;
    public float2 texCoords;
    public float3 geometryNormal;
    public float3 geometryTangent;
    public float3 tangentHandedness;
}

public struct SurfaceOutput {
    public float3 position;
    public float3 normal;
    public float3 baseColor;
    public float  alpha;
    public float3 emission;
    public float  ambientOcclusion;
}


