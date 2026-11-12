import lib.common;
import lib.mesh;

public struct VertexFetch {
    MeshRecord* mesh;
    uint        vertexID;
    uint        instanceIndex;
    float3x4    objectToWorld;

    public static VertexFetch Create(uint drawID, uint instanceID, uint vertexID) {
        let draw = Constants.draws[drawID];

        VertexFetch fetch;
        fetch.mesh = draw.meshRecord;
        fetch.vertexID = vertexID;
        fetch.instanceIndex = draw.instanceOffset + instanceID;
        fetch.objectToWorld = Constants.instances[fetch.instanceIndex].objectToWorld;
        return fetch;
    }

    public uint InstanceIndex() {
        return this.instanceIndex;
    }

    public float3x4 ObjectToWorld() {
        return this.objectToWorld;
    }

    public bool Has(uint attribute) {
        return MeshHas(this.mesh, attribute);
    }

    public float3 LocalPosition() {
        return MeshLoadFloat(this.mesh, this.vertexID, ATTR_POSITION, float4(0.0, 0.0, 0.0, 1.0)).xyz;
    }

    public float3 WorldPosition() {
        return mul(this.objectToWorld, float4(this.LocalPosition(), 1.0));
    }

    public float3 LocalNormal() {
        let normal = MeshLoadFloat(this.mesh, this.vertexID, ATTR_NORMAL, float4(0.0, 1.0, 0.0, 0.0)).xyz;
        return normalize(normal);
    }

    public float3 WorldNormal() {
        return normalize(mul(float3x3(this.objectToWorld), this.LocalNormal()));
    }

    public float4 LocalTangent() {
        let tangent = MeshLoadFloat(this.mesh, this.vertexID, ATTR_TANGENT, float4(1.0, 0.0, 0.0, 1.0));
        return float4(normalize(tangent.xyz), tangent.w < 0.0 ? -1.0 : 1.0);
    }

    public float4 WorldTangent() {
        let tangent = this.LocalTangent();
        return float4(normalize(mul(float3x3(this.objectToWorld), tangent.xyz)), tangent.w);
    }

    public float2 TexCoord0() {
        return MeshLoadFloat(this.mesh, this.vertexID, ATTR_TEX_COORD_0, float4(0.0)).xy;
    }

    public float2 TexCoord1() {
        return MeshLoadFloat(this.mesh, this.vertexID, ATTR_TEX_COORD_1, float4(0.0)).xy;
    }

    public float4 Color() {
        return MeshLoadFloat(this.mesh, this.vertexID, ATTR_COLOR, float4(1.0));
    }

    public uint4 Joints() {
        return MeshLoadUint(this.mesh, this.vertexID, ATTR_JOINTS);
    }

    public float4 Weights() {
        return MeshLoadFloat(this.mesh, this.vertexID, ATTR_WEIGHTS, float4(1.0, 0.0, 0.0, 0.0));
    }

    public float4 CustomFloat(uint index, float4 fallback = float4(0.0)) {
        return MeshLoadFloat(this.mesh, this.vertexID, ATTR_CUSTOM_0 + index, fallback);
    }

    public uint4 CustomUint(uint index) {
        return MeshLoadUint(this.mesh, this.vertexID, ATTR_CUSTOM_0 + index);
    }

    public bool HasCustom(uint index) {
        return MeshHas(this.mesh, ATTR_CUSTOM_0 + index);
    }
}
