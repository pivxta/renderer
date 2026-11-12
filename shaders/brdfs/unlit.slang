import lib.brdf;
import lib.math;
import lib.environment;
import lib.surface;

public struct UnlitBrdf: Brdf {
    public static bool IsLit() {
        return false;
    }

    public float3 Calculate(
        SurfaceOutput surface, 
        float3 omegaI, 
        float3 omegaO
    ) {
        return float3(0.0);
    }

    public float3 CalculateAmbient(
        SurfaceOutput surface, 
        Environment environment,
        float3 omegaO,
    ) {
        return float3(0.0);
    }
}
