import lib.brdf;
import lib.surface;

public interface Material {
    associatedtype B: Brdf;

    static Tuple<SurfaceOutput, B> Sample(uint64_t paramsAddress, SurfaceInput input);
}
