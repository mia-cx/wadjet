#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Convex-lens refraction for the selection capsule, iOS-tab-bar style:
// sample OUTSIDE the footprint — for a pixel at p, sample centre + (p−centre)·k
// with k rising toward the rim, so the bar (and what lies just past its edge)
// appears minified inside the lens. R/G/B get slightly different k near the
// rim for dispersion, plus a thin specular hairline.
[[ stitchable ]] half4 lens(float2 position, SwiftUI::Layer layer,
                            float2 centre, float2 size, float2 stretch,
                            float strength) {
    float2 c = position - centre;
    float2 half_ = size / 2.0;
    // capsule SDF in the (velocity-)stretched space
    float2 sc = float2(c.x / max(stretch.x, 1e-3), c.y / max(stretch.y, 1e-3));
    float r = min(half_.x, half_.y);
    float2 b = float2(max(half_.x - r, 0.0), max(half_.y - r, 0.0));
    float2 q = abs(sc) - b;
    float sdf = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    if (sdf >= 0.0) return layer.sample(position);

    // rim proximity: 0 deep inside, 1 at the rim
    float t = clamp(1.0 + sdf / r, 0.0, 1.0);
    float rim = smoothstep(0.0, 1.0, t);
    // minification factor: ~flat in the middle, pulls hard at the rim
    float k = mix(1.02, 1.9, rim * rim * (3.0 - 2.0 * rim)) * strength + (1.0 - strength);
    // dispersion: slightly different k per channel, only near the rim
    float dk = 0.06 * rim * strength;
    half4 o;
    o.r = layer.sample(centre + c * (k - dk)).r;
    o.g = layer.sample(centre + c * k).g;
    o.b = layer.sample(centre + c * (k + dk)).b;
    o.a = layer.sample(centre + c * k).a;
    // specular hairline just inside the rim
    float spec = smoothstep(0.86, 1.0, t) * (1.0 - smoothstep(0.985, 1.0, t)) * 0.28;
    // premultiplied: the hairline shows even where the sample is empty
    o.rgb += spec;
    o.a = max(o.a, half(spec));
    return o;
}
