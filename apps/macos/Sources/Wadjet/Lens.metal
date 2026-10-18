#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// The selection lens, iOS-tab-bar style. Inside the capsule the content is
// magnified (kCentre < 1); only a thin band at the rim compresses hard
// (k climbs past 1, pulling in what lies beyond the lens, so the bar's edges
// fold inside it), with per-channel dispersion in that band and a faint
// top-lit hairline. Samples are clamped to the source. `px` is one device
// pixel in points (1 / backingScaleFactor): the rim blends the last half-
// pixel instead of a hard 1-sample step. Gotchas: stitchable
// functions read program-scope `constant` globals as 0 (use #define), and
// writing a constant alpha (`o.a = 1`) blacks out the sampled channels —
// keep the whole sampled half4 and overwrite only r and b.
#define kCentre 0.80   // 1 / 0.8 = 1.25× magnification in the body
#define kRim 2.1       // how far the rim reaches outward
#define band 9.0       // rim band width in points
#define disp 0.07      // dispersion at the very edge


[[ stitchable ]] half4 lens(float2 position, SwiftUI::Layer layer,
                            float2 centre, float2 size, float2 stretch,
                            float2 bounds, float2 light, float px) {
    float2 c = position - centre;
    float2 half_ = size / 2.0;
    // capsule SDF in the (velocity-)stretched space, in points
    float2 sc = float2(c.x / max(stretch.x, 1e-3), c.y / max(stretch.y, 1e-3));
    float r = min(half_.x, half_.y);
    float2 b = float2(max(half_.x - r, 0.0), max(half_.y - r, 0.0));
    float2 q = abs(sc) - b;
    float sdf = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    // edge coverage blends the last half pixel — a hard step aliases
    if (sdf >= 0.5 * px) return layer.sample(position);
    float s = min(sdf, 0.0);

    // 0 in the body, 1 at the edge — only within `band` points of the rim
    float u = clamp(1.0 + s / band, 0.0, 1.0);
    float e = u * u * u;                       // stays flat, then climbs steeply
    float k = mix(kCentre, kRim, e);
    float dk = disp * e;
    float2 lo = float2(0.5), hi = bounds - 0.5;
    half4 o = layer.sample(clamp(centre + c * k, lo, hi));
    o.r = layer.sample(clamp(centre + c * (k - dk), lo, hi)).r;
    o.b = layer.sample(clamp(centre + c * (k + dk), lo, hi)).b;
    // faint hairline lit from the pointer, plus a small hotspot near it;
    // a light far above reproduces the old top-lit look
    float hair = smoothstep(-1.4, -0.5, s) * (1.0 - smoothstep(-0.5, 0.0, s));
    float2 ldir = normalize(light - centre);
    float facing = 0.35 + 0.65 * clamp(dot(normalize(sc), ldir) * 0.5 + 0.5, 0.0, 1.0);
    float spec = exp(-length(light - position) / 140.0) * 0.09;
    o.rgb += half(hair * (facing * 0.06 + spec));
    // coverage: sdf 0 → full effect, +half a px → plain backdrop
    return mix(layer.sample(position), o, half(clamp(0.5 - sdf / px, 0.0, 1.0)));
}

// The bar's own edge lensing: within `barEdge` points of the rounded-rect
// rim the sampled backdrop bends inward — p − n·f(dist) where n is the
// outward SDF normal and f eases ~6 pt at the edge to 0 — plus a faint
// top-lit edge highlight. Outside the rect: passthrough. The mask does the
// silhouette, so instead of blending at the edge the effect extends ~1.5 px
// past it (`s` clamps the SDF at 0 for the bands) — mask AA over a constant
// effect stays smooth. The layer this is applied to must contain backdrop
// beyond the bar's edge to bend.
#define barEdge 14.0
#define barPull 12.0
#define barTone 0.17     // grey the bar's tone leans toward
#define barToneMix 0.32  // how far it leans
#define barGlow 5.0      // inner edge glow width (pt)

static float rrSdf(float2 c, float2 half_, float r) {
    float2 b = float2(max(half_.x - r, 0.0), max(half_.y - r, 0.0));
    float2 q = abs(c) - b;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

[[ stitchable ]] half4 barGlass(float2 position, SwiftUI::Layer layer,
                                float2 rectOrigin, float2 rectSize,
                                float radius, float2 bounds, float2 light, float px) {
    float2 mid = rectOrigin + rectSize / 2.0;
    float2 c = position - mid;
    float2 half_ = rectSize / 2.0;
    float sdf = rrSdf(c, half_, radius);
    if (sdf >= 1.5 * px) return layer.sample(position);
    float s = min(sdf, 0.0); // bands extend past the edge; the mask owns the silhouette
    // outward normal by finite difference
    float e = 0.75;
    float2 n = normalize(float2(
        rrSdf(c + float2(e, 0), half_, radius) - rrSdf(c - float2(e, 0), half_, radius),
        rrSdf(c + float2(0, e), half_, radius) - rrSdf(c - float2(0, e), half_, radius)));
    float u = smoothstep(-barEdge, 0.0, s);     // 0 deep in, 1 at the edge
    float pull = u * u * barPull;
    float2 lo = float2(0.5), hi = bounds - 0.5;
    half4 o = layer.sample(clamp(position - n * pull, lo, hi));
    // dispersion in the edge band, like the lens — keep the sampled G/alpha
    float dk = 0.14 * u;
    o.r = layer.sample(clamp(position - n * pull * (1.0 - dk), lo, hi)).r;
    o.b = layer.sample(clamp(position - n * pull * (1.0 + dk), lo, hi)).b;
    // tone: pull everything toward a mid-dark grey, so the bar reads as a
    // surface over dark *and* bright backgrounds (a black tint vanishes on dark)
    o.rgb = mix(o.rgb, half3(barTone), half(barToneMix));
    // inner edge glow + a crisp rim hairline lit from the pointer, with a
    // hotspot that falls off ~140 pt — a light far above reproduces the old
    // top-lit look; the hotspot rides only the glow band and the hairline
    float facing = clamp(dot(n, normalize(light - position)) * 0.5 + 0.5, 0.0, 1.0);
    float spec = exp(-length(light - position) / 140.0) * 0.18;
    float glow = pow(smoothstep(-barGlow, 0.0, s), 2.0) * (0.07 + spec);
    float rim = (1.0 - smoothstep(0.0, 1.3, -s)) * (mix(0.07, 0.21, facing) + spec * 0.7);
    o.rgb += half(glow + rim);
    return o;
}
