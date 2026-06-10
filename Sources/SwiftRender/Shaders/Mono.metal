//
//  Mono.metal — the studio pack. High-frequency, crisp, each with its own
//  designed palette. Built for the LaunchFilm shader wall: detail over gradients.
//
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

static inline float mo_hash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

static inline float mo_noise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = mo_hash(i);
    float b = mo_hash(i + float2(1, 0));
    float c = mo_hash(i + float2(0, 1));
    float d = mo_hash(i + float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static inline float mo_fbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 6; i++) {
        v += a * mo_noise(p);
        p = p * 2.03 + float2(17.3, 9.1);
        a *= 0.5;
    }
    return v;
}

// =====================================================================
//  inkFlow — twice-domain-warped fBM. Silk marble, sharp ridgelines.
// =====================================================================
[[ stitchable ]]
half4 inkFlow(float2 position, half4 currentColor, float2 size, float time) {
    float2 uv = position / size;
    uv.x *= size.x / max(size.y, 1.0);
    float2 p = uv * 3.0;
    float t = time * 0.18;

    float2 q = float2(mo_fbm(p + t), mo_fbm(p + float2(5.2, 1.3) - t));
    float2 r = float2(mo_fbm(p + 4.0 * q + float2(1.7, 9.2) + t * 0.6),
                      mo_fbm(p + 4.0 * q + float2(8.3, 2.8) - t * 0.4));
    float f = mo_fbm(p + 4.0 * r);

    float g = clamp(f * f * 1.6, 0.0, 1.0);                  // deep contrast body
    float ridge = 1.0 - smoothstep(0.0, 0.05, abs(f - 0.5)); // thin bright vein
    float ridge2 = 1.0 - smoothstep(0.0, 0.03, abs(mo_fbm(p * 2.0 + r) - 0.5));

    float3 navy = float3(0.015, 0.04, 0.10);
    float3 teal = float3(0.05, 0.55, 0.60);
    float3 cream = float3(1.0, 0.94, 0.82);
    float3 col = mix(navy, teal, g * 0.9);
    col = mix(col, cream, clamp(ridge * 0.85 + ridge2 * 0.35, 0.0, 1.0));
    return half4(half3(clamp(col, 0.0, 1.0)), 1.0h);
}

// =====================================================================
//  metaballs — raymarched chrome blobs, real normals, fresnel + specular
// =====================================================================
static inline float mo_smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

static inline float mo_map(float3 p, float t) {
    float3 c1 = float3(sin(t * 0.70) * 0.85, cos(t * 0.90) * 0.50, sin(t * 0.30) * 0.2);
    float3 c2 = float3(cos(t * 0.50) * 0.90, sin(t * 1.10) * 0.55, cos(t * 0.45) * 0.3);
    float3 c3 = float3(sin(t * 1.25) * 0.55, cos(t * 0.65) * 0.70, sin(t * 0.85) * 0.25);
    float d = length(p - c1) - 0.55;
    d = mo_smin(d, length(p - c2) - 0.45, 0.45);
    d = mo_smin(d, length(p - c3) - 0.38, 0.45);
    return d;
}

[[ stitchable ]]
half4 metaballs(float2 position, half4 currentColor, float2 size, float time) {
    float2 uv = (position / size) * 2.0 - 1.0;
    uv.x *= size.x / max(size.y, 1.0);
    uv.y = -uv.y;

    float3 ro = float3(0.0, 0.0, -2.7);
    float3 rd = normalize(float3(uv, 1.7));
    float t = 0.0, d = 1.0;
    for (int i = 0; i < 64; i++) {
        d = mo_map(ro + rd * t, time);
        if (d < 0.001 || t > 6.0) break;
        t += d;
    }
    float g = 0.02;
    if (d < 0.01) {
        float3 p = ro + rd * t;
        float e = 0.0025;
        float3 n = normalize(float3(
            mo_map(p + float3(e, 0, 0), time) - mo_map(p - float3(e, 0, 0), time),
            mo_map(p + float3(0, e, 0), time) - mo_map(p - float3(0, e, 0), time),
            mo_map(p + float3(0, 0, e), time) - mo_map(p - float3(0, 0, e), time)));
        float3 l = normalize(float3(0.6, 0.8, -0.5));
        float diff = max(dot(n, l), 0.0);
        float fres = pow(1.0 - max(dot(n, -rd), 0.0), 3.0);
        float spec = pow(max(dot(reflect(-l, n), -rd), 0.0), 48.0);
        float chrome = 0.05 + diff * 0.30 + spec * 1.1;
        // iridescent rim: cosine palette driven by fresnel + view angle
        float h = fres * 2.2 + n.y * 0.6;
        float3 irid = 0.5 + 0.5 * cos(6.28318 * (h + float3(0.0, 0.33, 0.67)));
        float3 col = float3(chrome) + irid * fres * 0.85;
        return half4(half3(clamp(col, 0.0, 1.0)), 1.0h);
    }
    return half4(half3(float3(0.015, 0.015, 0.03)), 1.0h);
}

// =====================================================================
//  interference — three drifting wave sources, razor-thin zebra fringes
// =====================================================================
[[ stitchable ]]
half4 interference(float2 position, half4 currentColor, float2 size, float time) {
    float2 uv = position / size;
    uv.x *= size.x / max(size.y, 1.0);
    float t = time * 0.6;

    float2 s1 = float2(0.45 + 0.35 * sin(t * 0.7), 0.5 + 0.30 * cos(t * 0.9));
    float2 s2 = float2(1.20 + 0.40 * cos(t * 0.5), 0.5 + 0.35 * sin(t * 1.1));
    float2 s3 = float2(0.85 + 0.45 * sin(t * 0.8), 0.5 + 0.40 * cos(t * 0.6));

    float v = cos(length(uv - s1) * 70.0 - t * 4.0)
            + cos(length(uv - s2) * 64.0 + t * 3.2)
            + cos(length(uv - s3) * 58.0 - t * 2.5);
    float g = smoothstep(0.47, 0.53, 0.5 + v / 6.0);          // hard zebra edge
    float glow = exp(-abs(v) * 0.9);                          // soft node glow
    float3 indigo = float3(0.03, 0.02, 0.10);
    float3 cyan = float3(0.25, 0.92, 1.0);
    float3 magenta = float3(0.9, 0.2, 0.75);
    float3 col = indigo + cyan * g + magenta * glow * 0.30;
    return half4(half3(clamp(col, 0.0, 1.0)), 1.0h);
}

// =====================================================================
//  voronoiInk — drifting cells, thin white crack borders (F2 - F1)
// =====================================================================
[[ stitchable ]]
half4 voronoiInk(float2 position, half4 currentColor, float2 size, float time) {
    float2 uv = position / size;
    uv.x *= size.x / max(size.y, 1.0);
    float2 p = uv * 7.0;
    float2 ip = floor(p);

    float f1 = 8.0, f2 = 8.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float2 cell = ip + float2(x, y);
            float h = mo_hash(cell);
            float2 pt = cell + 0.5 + 0.42 * float2(sin(time * (0.5 + h) + h * 6.28),
                                                   cos(time * (0.4 + h) + h * 9.42));
            float d = length(p - pt);
            if (d < f1) { f2 = f1; f1 = d; }
            else if (d < f2) { f2 = d; }
        }
    }
    float border = 1.0 - smoothstep(0.0, 0.07, f2 - f1);      // thin crack lines
    float cellShade = 0.03 + 0.07 * mo_hash(ip);              // faint cell tone
    float core = exp(-f1 * 3.5);                              // cell nuclei
    float3 clay = float3(0.05, 0.045, 0.05) + cellShade * float3(0.5, 0.45, 0.5);
    float3 gold = float3(1.0, 0.76, 0.28);
    float3 ember = float3(0.85, 0.30, 0.12);
    float3 col = clay + gold * border * 0.95 + ember * core * 0.22;
    return half4(half3(clamp(col, 0.0, 1.0)), 1.0h);
}

// =====================================================================
//  monoTunnel — the warp tunnel, rebuilt monochrome and finer
// =====================================================================
[[ stitchable ]]
half4 monoTunnel(float2 position, half4 currentColor, float2 size, float time) {
    float2 uv = (position / size) * 2.0 - 1.0;
    uv.x *= size.x / max(size.y, 1.0);

    float r = max(length(uv), 1e-3);
    float a = atan2(uv.y, uv.x);
    float depth = 0.32 / r;
    float z = depth + time * 1.7;

    float rings = smoothstep(0.46, 0.5, abs(fract(z) - 0.5));
    float fine  = smoothstep(0.47, 0.5, abs(fract(z * 4.0) - 0.5)) * 0.35;
    float spokes = smoothstep(0.48, 0.5, abs(fract(a * 24.0 / 6.28318 + time * 0.04) - 0.5)) * 0.8;

    float fog = exp(-depth * 0.32);
    float g = clamp(rings + fine + spokes, 0.0, 1.0) * fog;
    float3 cyan = float3(0.30, 0.85, 1.0);
    float3 violet = float3(0.55, 0.25, 0.95);
    float3 tint = mix(cyan, violet, clamp(depth * 0.45, 0.0, 1.0));
    float3 col = tint * g;
    col += float3(1.0) * exp(-r * 4.5) * 0.55;                 // white-hot vanishing point
    return half4(half3(clamp(col, 0.0, 1.0)), 1.0h);
}
