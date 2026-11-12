import lib.brdf;
import lib.math;
import lib.environment;
import lib.surface;

public struct LambertBrdf: Brdf {
    public static bool IsLit() {
        return true;
    }

    public float3 Calculate(SurfaceOutput surface, float3 omegaI, float3 omegaO) {
        return surface.baseColor / PI;
    }

    public float3 CalculateAmbient(
        SurfaceOutput surface, 
        Environment environment,
        float3 omegaO,
    ) {
        return environment.ambientRadiance *
               surface.ambientOcclusion *
               surface.baseColor;
    }
}
