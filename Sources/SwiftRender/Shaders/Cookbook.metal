#include <metal_stdlib>
using namespace metal;

// =====================================================================
//  swift-render — Shader Cookbook
//
//  Six general-purpose motion-graphics fragment shaders. Each is a
//  [[ stitchable ]] entry point you can apply to any SwiftUI view via
//  `.colorEffect(ShaderLibrary.<name>(...))`.
//
//  These are LLM-friendly building blocks: each shader is self-contained,
//  small, documented, and takes only float / float2 / color params so an
//  agent can compose them into scenes without exotic types.
// =====================================================================

// ---------------------------------------------------------------------
//  Shared helpers
// ---------------------------------------------------------------------

static inline float ck_hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static inline float ck_noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = ck_hash21(i + float2(0,0));
    float b = ck_hash21(i + float2(1,0));
    float c = ck_hash21(i + float2(0,1));
    float d = ck_hash21(i + float2(1,1));
    return mix(mix(a,b,u.x), mix(c,d,u.x), u.y);
}

static inline float ck_fbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) {
        v += a * ck_noise(p);
        p *= 2.02;
        a *= 0.5;
    }
    return v;
}

// =====================================================================
//  rimGlow — soft glowing rim around the view's content edge
//
//  Usage:
//    .colorEffect(ShaderLibrary.rimGlow(
//        .float2(width, height),
//        .color(.red), .float(1.0), .float(time)))
// =====================================================================

[[ stitchable ]]
half4 rimGlow(
    float2 position,
    half4 currentColor,
    float2 size,
    half4 glowColor,
    float intensity,
    float time
) {
    if (currentColor.a < 0.001h) return currentColor;
    float2 uv = position / size;
    float2 c = uv * 2.0 - 1.0;
    float d = length(c);
    float rim = pow(d, 4.0);                   // grows toward edges
    float pulse = 0.85 + 0.15 * sin(time * 2.0);
    float3 glow = float3(glowColor.rgb) * rim * pulse * intensity * 0.6;
    float3 out = float3(currentColor.rgb) + glow;
    return half4(half3(out), currentColor.a);
}

// =====================================================================
//  foilHolographic — iridescent rainbow film over the surface
//
//  Apply on top of dark surfaces. Hue cycles across a diagonal phase
//  ramp; intensity controls amplitude.
// =====================================================================

[[ stitchable ]]
half4 foilHolographic(
    float2 position,
    half4 currentColor,
    float2 size,
    float seed,
    float intensity
) {
    if (currentColor.a < 0.001h) return currentColor;
    float2 uv = position / size;
    float2 c = uv * 2.0 - 1.0;
    float aspect = size.x / max(size.y, 1.0);
    c.x *= aspect;

    float phase = (c.x * 0.6 + c.y * 0.7) * 2.4 + seed * 6.28;
    float3 hue = 0.5 + 0.5 * cos(6.28318 * (phase + float3(0.0, 0.33, 0.67)));
    float fres = pow(clamp(length(c) * 0.7, 0.0, 1.0), 2.0);
    hue *= (0.6 + 0.4 * fres);

    float amp = clamp(intensity, 0.0, 1.0) * 0.30;
    float3 base = float3(currentColor.rgb);
    float3 screened = 1.0 - (1.0 - base) * (1.0 - hue * amp);
    return half4(half3(screened), currentColor.a);
}

// =====================================================================
//  plasmaField — flowing animated noise. Background filler for intros.
// =====================================================================

[[ stitchable ]]
half4 plasmaField(
    float2 position,
    half4 currentColor,
    float2 size,
    float time,
    float scale
) {
    float2 uv = position / size;
    float2 p = (uv * 2.0 - 1.0) * scale;
    float n = ck_fbm(p + float2(time * 0.15, time * 0.10));
    float n2 = ck_fbm(p * 1.6 - float2(time * 0.20, 0.0));
    float v = mix(n, n2, 0.5);

    float3 a = float3(0.04, 0.02, 0.10);
    float3 b = float3(0.10, 0.35, 0.85);
    float3 c = float3(0.85, 0.20, 0.45);
    float3 col = mix(a, b, v) + c * pow(v, 6.0) * 0.4;
    return half4(half3(col), 1.0h);
}

// =====================================================================
//  chromaticAberration — RGB channel split at the frame edges
// =====================================================================

[[ stitchable ]]
half4 chromaticAberration(
    float2 position,
    half4 currentColor,
    float2 size,
    float amount
) {
    if (currentColor.a < 0.001h) return currentColor;
    float2 uv = position / size;
    float2 c = uv * 2.0 - 1.0;
    float r = length(c);
    // Simulate offset by darkening green/blue toward edges to suggest split.
    float ar = clamp(amount, 0.0, 1.0);
    half3 col = currentColor.rgb;
    col.g *= (1.0h - half(r * ar * 0.20));
    col.b *= (1.0h - half(r * ar * 0.35));
    col.r *= (1.0h - half(r * ar * 0.05));
    return half4(col, currentColor.a);
}

// =====================================================================
//  audioBars — symmetric audio-reactive frequency bars across the frame
//
//  Useful as a background for music visualizations and lyric videos.
// =====================================================================

[[ stitchable ]]
half4 audioBars(
    float2 position,
    half4 currentColor,
    float2 size,
    float level,
    float barCount,
    float time
) {
    float2 uv = position / size;
    float bars = max(barCount, 1.0);
    float x = uv.x * bars;
    int idx = int(floor(x));
    float center = bars * 0.5;
    float dist = abs(float(idx) - center);

    // Layered traveling waves
    float p1 = time * 3.5 - dist * 0.32;
    float p2 = time * 6.2 + dist * 0.22;
    float w = (sin(p1) * 0.5 + 0.5) * 0.55 + (sin(p2) * 0.5 + 0.5) * 0.45;
    float lvl = max(0.18, level);
    float h = clamp(w * lvl * 1.6, 0.15, 1.0);

    float vertCenter = 0.5;
    float dY = abs(uv.y - vertCenter);
    float inside = step(dY, h * 0.5);
    float3 col = float3(currentColor.rgb) + inside * 0.6;
    return half4(half3(col), 1.0h);
}

// =====================================================================
//  caustics — pool-of-water animated highlight pattern
// =====================================================================

[[ stitchable ]]
half4 caustics(
    float2 position,
    half4 currentColor,
    float2 size,
    float time,
    float intensity
) {
    float2 uv = position / size;
    float2 p = uv * 6.0;
    float v = 0.0;
    for (int i = 0; i < 3; i++) {
        float fi = float(i) + 1.0;
        v += sin(p.x * fi * 1.3 + time * 0.7 * fi) *
             sin(p.y * fi * 1.7 - time * 0.5 * fi);
    }
    v = pow(max(0.0, v / 3.0 + 0.5), 4.0);
    float3 base = float3(currentColor.rgb);
    float3 hit = float3(0.6, 0.85, 1.0) * v * clamp(intensity, 0.0, 1.0);
    return half4(half3(base + hit), 1.0h);
}
