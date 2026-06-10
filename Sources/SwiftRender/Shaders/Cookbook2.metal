#include <metal_stdlib>
using namespace metal;

// =====================================================================
//  swift-render — Cookbook Vol. 2
//
//  Six "wow factor" shaders inspired by classic demoscene + shadertoy
//  patterns. Drop-in stitchable shaders callable via
//  `.colorEffect(ShaderLibrary.bundle(.module).<name>(...))`.
//
//  These complement Cookbook.metal — fresh visual vocabulary for AI
//  agents writing motion graphics.
// =====================================================================

static inline float c2_hash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

static inline float c2_noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = c2_hash(i);
    float b = c2_hash(i + float2(1.0, 0.0));
    float c = c2_hash(i + float2(0.0, 1.0));
    float d = c2_hash(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static inline float c2_fbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 5; i++) {
        v += a * c2_noise(p);
        p *= 2.02;
        a *= 0.5;
    }
    return v;
}

// =====================================================================
//  liquidMetal — flowing chrome-silver surface with fresnel edges
// =====================================================================

[[ stitchable ]]
half4 liquidMetal(
    float2 position,
    half4 currentColor,
    float2 size,
    float time
) {
    float2 uv = position / size;
    float2 p = uv * 2.0 - 1.0;
    p.x *= size.x / max(size.y, 1.0);

    // Domain-warped flow
    float w1 = sin(p.x * 2.3 + time * 0.6) + cos(p.y * 1.7 - time * 0.5);
    float w2 = sin(p.x * 3.1 - time * 0.4) + cos(p.y * 2.4 + time * 0.3);
    float2 q = p + 0.30 * float2(w1, w2);
    float pattern = sin(dot(q, q) * 3.0 - time);

    float v = pow(pattern * 0.5 + 0.5, 1.4);
    float3 dark   = float3(0.04, 0.05, 0.07);
    float3 silver = float3(0.72, 0.78, 0.85);
    float3 col    = mix(dark, silver, v);

    float fres = pow(clamp(length(p) * 0.7, 0.0, 1.0), 3.0);
    col += float3(0.42, 0.48, 0.55) * fres * 0.55;

    return half4(half3(col), 1.0h);
}

// =====================================================================
//  kaleidoscope — symmetric mirror pattern that rotates over time
// =====================================================================

[[ stitchable ]]
half4 kaleidoscope(
    float2 position,
    half4 currentColor,
    float2 size,
    float time,
    float segments
) {
    float2 uv = position / size;
    float2 p = uv * 2.0 - 1.0;
    p.x *= size.x / max(size.y, 1.0);

    float r = length(p);
    float a = atan2(p.y, p.x);

    float seg = 6.28318 / max(segments, 3.0);
    a = abs(fmod(a + time * 0.20, seg) - seg * 0.5);

    float2 q = float2(cos(a), sin(a)) * r;
    float n = sin(q.x * 8.0 + time * 0.7) * sin(q.y * 8.0 - time * 0.5);
    n = n * 0.5 + 0.5;

    float3 hot  = float3(0.95, 0.40, 0.18);
    float3 cool = float3(0.22, 0.45, 0.95);
    float3 col  = mix(cool, hot, n);
    col *= 1.0 - clamp(r * 0.35, 0.0, 1.0);

    return half4(half3(col), 1.0h);
}

// =====================================================================
//  truchet — endless connecting arcs forming weaving paths
// =====================================================================

[[ stitchable ]]
half4 truchet(
    float2 position,
    half4 currentColor,
    float2 size,
    float time,
    float scale
) {
    float2 uv = position / size;
    float2 p = uv * max(scale, 2.0) + float2(time * 0.10, time * 0.05);

    float2 ip = floor(p);
    float2 fp = fract(p);

    float h = c2_hash(ip);
    if (h > 0.5) fp.x = 1.0 - fp.x;

    float d1 = abs(distance(fp, float2(0.0, 0.0)) - 0.5);
    float d2 = abs(distance(fp, float2(1.0, 1.0)) - 0.5);
    float d = min(d1, d2);

    float thick = 0.075 + 0.025 * sin(time * 1.5);
    float line = 1.0 - smoothstep(thick, thick + 0.02, d);

    float3 bg = float3(0.06, 0.04, 0.12);
    float3 fg = float3(0.92, 0.85, 0.70);
    float3 col = mix(bg, fg, line);
    return half4(half3(col), 1.0h);
}

// =====================================================================
//  galaxy — animated spiral galaxy with bright core + star field
// =====================================================================

[[ stitchable ]]
half4 galaxy(
    float2 position,
    half4 currentColor,
    float2 size,
    float time
) {
    float2 uv = position / size;
    float2 p = uv * 2.0 - 1.0;
    p.x *= size.x / max(size.y, 1.0);

    float r = length(p);
    float a = atan2(p.y, p.x);

    // Two spiral arms (log-spiral)
    float arm1 = sin(a * 2.0 + log(r * 4.0 + 0.5) * 5.0 - time * 0.30);
    float arm2 = sin(a * 2.0 + log(r * 4.0 + 0.5) * 5.0 - time * 0.30 + 3.14159);
    float density = pow(max(0.0, arm1), 4.0) * 0.5
                  + pow(max(0.0, arm2), 4.0) * 0.5;
    density *= 1.0 - smoothstep(0.0, 1.2, r);
    density *= smoothstep(0.02, 0.18, r);

    float core = exp(-r * r * 7.0) * 1.4;

    // Star scatter — round point stars inside each hash cell, not whole cells
    float2 ip = floor(p * 35.0);
    float2 fp = fract(p * 35.0) - 0.5;
    float h = c2_hash(ip);
    float twinkle = 0.75 + 0.25 * sin(time * 3.0 + h * 40.0);
    float star = smoothstep(0.978, 1.0, h)
               * smoothstep(0.28, 0.0, length(fp))
               * twinkle;

    float3 arms = float3(0.45, 0.65, 1.00) * density;
    float3 sun  = float3(1.00, 0.85, 0.55) * core;
    float3 col  = arms + sun;
    col += float3(1.0) * star * 0.7;
    col *= 0.95;

    return half4(half3(col), 1.0h);
}

// =====================================================================
//  neonGrid — synthwave perspective grid + retro sun
// =====================================================================

[[ stitchable ]]
half4 neonGrid(
    float2 position,
    half4 currentColor,
    float2 size,
    float time
) {
    float2 uv = position / size;
    float2 p = float2(uv.x, 1.0 - uv.y);

    if (p.y < 0.45) {
        // GROUND — receding perspective grid
        float t = p.y / 0.45;                      // 0 at horizon, 1 at bottom
        float persp = mix(0.05, 1.0, t);
        float gx = (p.x - 0.5) / persp + 0.5;
        float gy = t * 3.5 + time * 0.55;

        float lineX = smoothstep(0.02, 0.0, abs(fract(gx * 12.0) - 0.5));
        float lineY = smoothstep(0.04, 0.0, fract(gy));
        float line = clamp(lineX + lineY, 0.0, 1.0);

        float3 floor = float3(0.05, 0.0, 0.12);
        float3 neon  = float3(1.00, 0.20, 0.60);
        return half4(half3(mix(floor, neon, line * 0.85)), 1.0h);
    }

    // SKY gradient
    float t = (p.y - 0.45) / 0.55;
    float3 sky = mix(float3(1.0, 0.22, 0.58), float3(0.08, 0.02, 0.18), t);

    // Sun disc
    float2 sunVec = float2(0.5, 0.62) - p;
    sunVec.x *= size.x / max(size.y, 1.0);
    float dSun = length(sunVec);
    float sunMask = smoothstep(0.20, 0.19, dSun);
    float3 sunCol = mix(float3(1.0, 0.85, 0.35), float3(1.0, 0.35, 0.55),
                        (p.y - 0.42) / 0.40);
    sky = mix(sky, sunCol, sunMask);

    // Horizontal lines through the sun
    float yIn = (p.y - 0.42) * 18.0;
    float bandMask = step(fract(yIn), 0.55);
    sky = mix(sky, sky * 0.35 + float3(0.02), sunMask * (1.0 - bandMask));

    return half4(half3(sky), 1.0h);
}

// =====================================================================
//  smokeFlow — turbulent flowing smoke / nebula via domain warping
// =====================================================================

[[ stitchable ]]
half4 smokeFlow(
    float2 position,
    half4 currentColor,
    float2 size,
    float time
) {
    float2 uv = position / size;
    float2 p = uv * 3.0;

    float2 q = float2(
        c2_fbm(p + time * 0.05),
        c2_fbm(p + float2(5.2, 1.3) + time * 0.07)
    );
    float2 r2 = float2(
        c2_fbm(p + 4.0 * q + float2(1.7, 9.2) + time * 0.10),
        c2_fbm(p + 4.0 * q + float2(8.3, 2.8) + time * 0.08)
    );
    float v = c2_fbm(p + 4.0 * r2);

    float3 dark  = float3(0.05, 0.04, 0.10);
    float3 mid   = float3(0.55, 0.30, 0.75);
    float3 light = float3(1.00, 0.85, 0.95);
    float3 col = mix(dark, mid, v);
    col = mix(col, light, pow(v, 4.0));

    return half4(half3(col), 1.0h);
}
