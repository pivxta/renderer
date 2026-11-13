import lib.texture;
import lib.material;
import lib.surface;
import brdfs.lambert;

static const uint HAS_BASE_COLOR_TEXTURE = 1 << 0;
static const uint HAS_NORMAL_MAP = 1 << 1;

public struct LambertMaterial: Material {
    typealias B = LambertBrdf;

    struct Params {
        float4 baseColorFactor;
        float normalFactor;
        BindlessTexture2D baseColorTexture;
        BindlessTexture2D normalMap;
        BindlessSampler sampler;
        uint flags;
    }

    static Tuple<SurfaceOutput, LambertBrdf> Sample(uint64_t paramsAddress, SurfaceInput input) {
        let params = *(Params*)paramsAddress;

        var baseColor = params.baseColorFactor;
        if ((params.flags & HAS_BASE_COLOR_TEXTURE) != 0) {
            baseColor *= params.baseColorTexture.Sample(params.sampler, input.texCoords); 
        }

        let geometryNormal = input.geometryNormal;
        let geometryTangent = input.geometryTangent;
        let geometryBitangent = input.tangentHandedness * cross(geometryNormal, geometryTangent);
        var localNormal = float3(0.0, 0.0, 1.0);
        if ((params.flags & HAS_NORMAL_MAP) != 0) {
            let sampledNormal = params.normalMap.Sample(params.sampler, input.texCoords).xyz;
            localNormal = 2.0 * sampledNormal - 1.0;
        }
        let normal = normalize(
            localNormal.z * geometryNormal +
            localNormal.x * geometryTangent * params.normalFactor +
            localNormal.y * geometryBitangent * params.normalFactor
        );

        SurfaceOutput surfaceOut = {};
        surfaceOut.position = input.position;
        surfaceOut.normal = normal;
        surfaceOut.baseColor = baseColor.rgb;
        surfaceOut.alpha = baseColor.a;
        surfaceOut.emission = float3(0.0);
        surfaceOut.ambientOcclusion = 1.0;
        return {surfaceOut, {}};
    }
}
