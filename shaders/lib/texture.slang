[[vk::binding(0, 0)]]
SamplerState[] samplers;

[[vk::binding(0, 1)]]
Texture2D[] textures;

public struct BindlessTexture2D {
    uint index;

    public Texture2D GetResource() {
        return textures[NonUniformResourceIndex(this.index)];
    }

    public float4 Sample(BindlessSampler sampler, float2 coords) {
        return this.GetResource().Sample(sampler.GetResource(), coords);
    }

    public float4 SampleGrad(BindlessSampler sampler, float2 coords, float2 dx, float2 dy) {
        return this.GetResource().SampleGrad(sampler.GetResource(), coords, dx, dy);
    }
}

public struct BindlessSampler {
    uint index;

    public SamplerState GetResource() {
        return samplers[NonUniformResourceIndex(this.index)];
    }
}
