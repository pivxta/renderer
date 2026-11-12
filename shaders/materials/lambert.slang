import lib.texture;
import lib.material;
import lib.surface;
import brdfs.lambert;

static const uint HAS_BASE_COLOR_TEXTURE = 1 << 0;

public struct LambertMaterial: Material {
    typealias B = LambertBrdf;

    struct Params {
        float4 baseColorFactor;
        BindlessTexture2D baseColor;
        BindlessSampler sampler;
        uint flags;
    }

    static Tuple<SurfaceOutput, LambertBrdf> Sample(uint64_t paramsAddress, SurfaceInput input) {
        let params = *(Params*)paramsAddress;
    
        var baseColor = params.baseColorFactor;
        if ((params.flags & HAS_BASE_COLOR_TEXTURE) != 0) {
            baseColor *= params.baseColor.Sample(params.sampler, input.texCoords); 
        }

        SurfaceOutput surfaceOut = {};
        surfaceOut.position = input.position;
        surfaceOut.normal = input.geometryNormal;
        surfaceOut.baseColor = baseColor.rgb;
        surfaceOut.alpha = baseColor.a;
        surfaceOut.emission = float3(0.0);
        surfaceOut.ambientOcclusion = 1.0;
        return {surfaceOut, {}};
    }
}
