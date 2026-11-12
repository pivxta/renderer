import lib.light;
import lib.surface;
import lib.environment;

public interface Brdf {
    static bool IsLit(); 
    float3 Calculate(
        SurfaceOutput surface, 
        float3 omegaI, 
        float3 omegaO
    );
    float3 CalculateAmbient(
        SurfaceOutput surface, 
        Environment environment,
        float3 omegaO,
    );
}

public float3 CalculateRadiance<B: Brdf, L: Light>(
    B brdf,
    L light,
    SurfaceOutput surface,
    float3 viewPosition,
) {
    if (light.ShouldCull(surface.position)) {
        return float3(0.0);
    }

    let omegaI = light.GetOmegaI(surface.position);
    let omegaO = normalize(viewPosition - surface.position);
    let lambert = max(dot(omegaI, surface.normal), 0.0);
    return brdf.Calculate(surface, omegaI, omegaO) *
           light.GetIncidentRadiance(surface.position) *
           lambert;
}
