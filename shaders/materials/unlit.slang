import lib.texture;
import lib.material;
import lib.surface;
import brdfs.unlit;

static const uint HAS_COLOR_TEXTURE = 1 << 0;

public struct UnlitMaterial: Material {
    typealias B = UnlitBrdf;

    struct Params {
        float3 colorFactor;
        BindlessTexture2D color;
        BindlessSampler sampler;
        uint flags;
    }

    static Tuple<SurfaceOutput, UnlitBrdf> Sample(uint64_t paramsAddress, SurfaceInput input) {
        let params = *(Params*)paramsAddress;
    
        var emission = params.colorFactor;
        if ((params.flags & HAS_COLOR_TEXTURE) != 0) {
            emission *= params.color.Sample(params.sampler, input.texCoords).rgb; 
        }

        SurfaceOutput surfaceOut = {};
        surfaceOut.position = input.position;
        surfaceOut.normal = input.geometryNormal;
        surfaceOut.baseColor = float3(0.0);
        surfaceOut.alpha = 1.0;
        surfaceOut.emission = emission;
        surfaceOut.ambientOcclusion = 0.0;
        return {surfaceOut, {}};
    }
}

