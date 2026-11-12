import lib.math;
import lib.environment;

public struct Lighting {
    public float ambientIlluminance;
    public float3 ambientColor;
    public PointLight* pointLights;
    public uint pointLightCount;
    public DirLight* dirLights;
    public uint dirLightCount;

    public Environment GetEnvironment() {
        return {this.ambientIlluminance * this.ambientColor / PI};
    }
}

public interface Light {
    float3 GetIncidentRadiance(float3 position);
    float3 GetOmegaI(float3 position);
    bool ShouldCull(float3 position);
}

public struct PointLight: Light {
    float3 position;
    float radius;
    float power;
    float3 color;

    bool ShouldCull(float3 position) {
        let fragmentToLight = this.position - position;
        return dot(fragmentToLight, fragmentToLight) > this.radius * this.radius;
    }

    float3 GetIncidentRadiance(float3 position) {
        let toLight = this.position - position;
        let distanceSq = dot(toLight, toLight);
        var fadeOut = saturate(1.0 - pow(distanceSq / (this.radius * radius), 2.0));
        fadeOut *= fadeOut;
        return (fadeOut * this.power * this.color) / max(4.0 * PI * distanceSq, 0.0001);
    }

    float3 GetOmegaI(float3 position) {
        return normalize(this.position - position);
    }
}

public struct DirLight: Light {
    float3 direction;
    float illuminance;
    float3 color;

    bool ShouldCull(float3 position) {
        return false;
    }

    float3 GetIncidentRadiance(float3 position) {
        return this.illuminance * this.color;
    }

    float3 GetOmegaI(float3 position) {
        return normalize(-this.direction);
    }
}

