#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// The selection lens, iOS-tab-bar style. Inside the capsule the content is
// magnified (kCentre < 1); only a thin band at the rim compresses hard
// (k climbs past 1, pulling in what lies beyond the lens, so the bar's edges
// fold inside it), with per-channel dispersion in that band and a faint
// top-lit hairline. Samples are clamped to the source. Gotchas: stitchable
// functions read program-scope `constant` globals as 0 (use #define), and
// writing a constant alpha (`o.a = 1`) blacks out the sampled channels —
// keep the whole sampled half4 and overwrite only r and b.
#define kCentre 0.80   // 1 / 0.8 = 1.25× magnification in the body
#define kRim 2.1       // how far the rim reaches outward
#define band 9.0       // rim band width in points
#define disp 0.07      // dispersion at the very edge


[[ stitchable ]] half4 lens(float2 position, SwiftUI::Layer layer,
                            float2 centre, float2 size, float2 stretch,
                            float2 bounds) {
    float2 c = position - centre;
    float2 half_ = size / 2.0;
    // capsule SDF in the (velocity-)stretched space, in points
    float2 sc = float2(c.x / max(stretch.x, 1e-3), c.y / max(stretch.y, 1e-3));
    float r = min(half_.x, half_.y);
    float2 b = float2(max(half_.x - r, 0.0), max(half_.y - r, 0.0));
    float2 q = abs(sc) - b;
    float sdf = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    if (sdf >= 0.0) return layer.sample(position);

    // 0 in the body, 1 at the edge — only within `band` points of the rim
    float u = clamp(1.0 + sdf / band, 0.0, 1.0);
    float e = u * u * u;                       // stays flat, then climbs steeply
    float k = mix(kCentre, kRim, e);
    float dk = disp * e;
    float2 lo = float2(0.5), hi = bounds - 0.5;
    half4 o = layer.sample(clamp(centre + c * k, lo, hi));
    o.r = layer.sample(clamp(centre + c * (k - dk), lo, hi)).r;
    o.b = layer.sample(clamp(centre + c * (k + dk), lo, hi)).b;
    // faint hairline, brighter toward the top edge (light from above)
    float hair = smoothstep(-1.4, -0.5, sdf) * (1.0 - smoothstep(-0.5, 0.0, sdf));
    float topLit = 0.35 + 0.65 * clamp(-sc.y / max(half_.y, 1.0) * 0.5 + 0.5, 0.0, 1.0);
    o.rgb += half(hair * topLit * 0.06);
    return o;
}
