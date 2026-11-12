import lib.mesh;
import lib.light;

[[vk::push_constant]] public ConstantBuffer<PushConstants> Constants;

public struct PushConstants {
    public View*     view;
    public Draw*     draws;
    public Instance* instances;
    public Lighting* lighting;
}

public struct Draw {
    public MeshRecord* meshRecord; 
    public uint        instanceOffset; 
} 

public struct View {
    public float4x4 worldToClip;
    public float3   position;
}

public struct Instance {
    public float3x4  objectToWorld;
    public uint64_t  materialAddress;
    public uint      materialType;
}


