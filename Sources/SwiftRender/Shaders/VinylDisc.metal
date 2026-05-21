#include <metal_stdlib>
using namespace metal;

// ══════════════════════════════════════════════════════════════════
// Spinning vinyl disc shader — optimized for many-disc grid rendering
// ══════════════════════════════════════════════════════════════════
//
// Disc content (grooves, scratches, paper grain) is sampled from a
// UV that's counter-rotated by -spinRadians inside the shader, so
// patterns rotate with the disc. Lighting (anisotropic highlight,
// broad shine, tight spec, label light) is computed from the
// ORIGINAL world-frame UV, so the bright band stays rock-still at
// upper-left regardless of spin angle or hover state.
//
// CRITICAL: the parent view must NOT wrap this shader's output in a
// `.rotationEffect`. All rotation is internal. An outer rotation
// would drag the baked-in light band along with the rasterized
// pixels, and any counter-rotation in the shader would still race
// CoreAnimation during `withAnimation` — you'd see the light band
// "slide" across the disc. Keep rotation inside the shader.
//
// PERFORMANCE: two early-out branches based on `dist`:
//
//   1. dist < labelR - 0.005  (~17% of pixels)
//      Strict label interior — skip groove / scratch / highlight /
//      rim work entirely. Saves ~9 sin calls + ~3 pow calls per
//      label pixel.
//
//   2. dist >= labelR + 0.004 (~82% of pixels)
//      Pure vinyl body — skip the label-color computation
//      (labelGrad, paperGrain, inner circles, labelLight). Saves
//      ~1 sin call + ~1 pow call per vinyl pixel.
//
// Only the narrow ~1% transition annulus runs the full code path.
// Both branches are uniform on dist and stay warp-coherent because
// the regions are radially clustered.

// Hash function for per-disc randomization
float hash(float n) {
    return fract(sin(n) * 43758.5453123);
}

[[ stitchable ]]
half4 spinningVinyl(
    float2 position,
    half4 currentColor,
    float2 size,
    float time,
    float seed,
    half4 labelColor,
    half4 accentColor,
    float2 mouseNorm,
    float hoverActive,
    float spinRadians
) {
    float2 uv = (position / size) * 2.0 - 1.0;
    float dist = length(uv);

    if (dist > 1.0) return half4(0.0);

    // Counter-rotate UV by -spinRadians to recover the disc's local
    // frame. Grooves/scratches are sampled from uvLocal (rotates with
    // disc). Lighting is computed from world-frame dir (stays fixed).
    float cs = cos(spinRadians);
    float sn = sin(spinRadians);
    float2 uvLocal = float2(
        uv.x * cs + uv.y * sn,
        -uv.x * sn + uv.y * cs
    );
    float angleLocal = atan2(uvLocal.y, uvLocal.x);

    // World-frame direction — lighting stays fixed at upper-left.
    float2 dir = normalize(uv);

    // Key light from upper-left at 45°. Immutable across rotation.
    const float2 lightDir = float2(0.7071067811865475, 0.7071067811865475);
    float NdotL = dot(dir, -lightDir);

    // r1 is shared by both branches (paperGrain in label, groove +
    // scratch seeding in vinyl). r2–r5 are computed only in the
    // vinyl branch to save 4 hash calls on label pixels.
    float r1 = hash(seed);

    const float labelR = 0.42;
    const float holeR = 0.035;

    // ══════════════════════════════════════════════════════════════
    // ① LABEL EARLY-OUT — dist < labelR - 0.005 (~17% of pixels)
    // ══════════════════════════════════════════════════════════════
    if (dist < labelR - 0.005) {
        // Label paper color with radial gradient toward the hole
        float3 labelCol = float3(labelColor.rgb);
        float labelGrad = smoothstep(labelR, holeR + 0.03, dist);
        labelCol *= mix(0.65, 1.0, labelGrad);

        // Paper grain — rotates with disc via angleLocal
        float paperGrain = sin(angleLocal * 200.0 + dist * 500.0 + r1 * 100.0) * 0.02 + 0.98;
        labelCol *= paperGrain;

        // Inner decorative circles (two concentric rings)
        float innerCircle1 = smoothstep(0.22, 0.215, dist) * smoothstep(0.19, 0.195, dist);
        float innerCircle2 = smoothstep(0.14, 0.135, dist) * smoothstep(0.10, 0.105, dist);
        labelCol = mix(labelCol, labelCol * 0.85, innerCircle1 * 0.4);
        labelCol = mix(labelCol, float3(accentColor.rgb) * 0.9, innerCircle2 * 0.15);

        // Label catches a small amount of the world-space key light
        float labelLight = pow(max(0.0, NdotL), 3.0) * 0.03;
        labelCol += labelLight;

        // Chrome center hole + ring
        float hole = smoothstep(holeR - 0.005, holeR + 0.008, dist);
        float holeRing = smoothstep(holeR + 0.012, holeR + 0.006, dist) *
                         smoothstep(holeR - 0.005, holeR + 0.002, dist);
        float3 holeMetal = float3(0.6, 0.6, 0.62);
        holeMetal += pow(max(0.0, NdotL), 8.0) * 0.2;
        float3 color = mix(labelCol, holeMetal, holeRing);
        float luma1 = dot(color, float3(0.2126, 0.7152, 0.0722));
        color = mix(float3(luma1), color, mix(0.35, 1.0, hoverActive));
        color += mix(-0.04, 0.0, hoverActive);
        return half4(half3(color), half(hole));
    }

    // ══════════════════════════════════════════════════════════════
    // VINYL PATH (dist >= labelR - 0.005)
    // ══════════════════════════════════════════════════════════════

    // Remaining per-disc randomization (vinyl path only)
    float r2 = hash(seed + 1.0);
    float r3 = hash(seed + 2.0);
    float r4 = hash(seed + 3.0);
    float r5 = hash(seed + 4.0);

    // Tangent for anisotropic highlight — already normalized because
    // |(-uv.y, uv.x)| = |uv| = dist.
    float2 tangent = float2(-uv.y, uv.x) / max(dist, 0.001);

    // Outer disc edge + rim ring
    float edge = smoothstep(1.0, 0.985, dist);
    float rim = smoothstep(0.985, 0.975, dist) * smoothstep(0.96, 0.975, dist);

    // Grooves — randomized frequency per disc, radially symmetric
    // so we sample `dist` directly (rotation-invariant by design).
    float grooveFreq1 = 700.0 + r1 * 200.0;   // 700–900
    float grooveFreq2 = 160.0 + r2 * 80.0;    // 160–240
    float grooveFreq3 = 30.0 + r3 * 20.0;     //  30– 50
    float microGroove = sin(dist * grooveFreq1) * 0.5 + 0.5;
    float medGroove   = sin(dist * grooveFreq2) * 0.5 + 0.5;
    float broadBand   = sin(dist * grooveFreq3) * 0.5 + 0.5;
    float grooveMod   = 0.85 + microGroove * 0.05 + medGroove * 0.05 + broadBand * 0.05;

    // Anisotropic highlight — perpendicular band relative to light.
    // Masked out near label (0.42–0.47) and near outer edge (0.95–0.99).
    float TdotH = dot(tangent, lightDir);
    float anisoSpec = pow(1.0 - TdotH * TdotH, 8.0) * 0.10;
    anisoSpec *= smoothstep(labelR, labelR + 0.05, dist);
    anisoSpec *= smoothstep(0.99, 0.95, dist);

    // Broad Lambertian shine on the lit side
    float broadShine = pow(max(0.0, NdotL), 5.0) * 0.06;
    broadShine *= smoothstep(labelR, labelR + 0.08, dist);

    // Tight specular dot at the brightest point
    float tightSpec = pow(max(0.0, NdotL), 40.0) * 0.10;
    tightSpec *= smoothstep(labelR, labelR + 0.05, dist);

    // Radial micro-lines — rotate with disc via angleLocal
    float radialCount1 = 200.0 + r1 * 150.0;
    float radialCount2 =  50.0 + r2 *  60.0;
    float radialFine = sin(angleLocal * radialCount1 + r3 * 6.28) * 0.5 + 0.5;
    float radialMed  = sin(angleLocal * radialCount2 + dist * 15.0 + r4 * 6.28) * 0.5 + 0.5;
    float radialDetail = 0.98 + radialFine * 0.01 + radialMed * 0.01;

    // Unique arc scratches per disc
    float arcFreq1 = 3.0 + r1 * 5.0;
    float arcFreq2 = 5.0 + r2 * 7.0;
    float arcDist1 = 40.0 + r3 * 30.0;
    float arcDist2 = 30.0 + r4 * 25.0;
    float arc1 = sin(angleLocal * arcFreq1 + dist * arcDist1 + r5 * 6.28) *
                 sin(angleLocal * (arcFreq1 + 6.0) - dist * arcDist2);
    float arc2 = sin(angleLocal * arcFreq2 + dist * arcDist2 + r1 * 6.28) *
                 sin(angleLocal * (arcFreq2 + 4.0) + dist * arcDist1);
    float wornScratch = smoothstep(0.88, 0.96, arc1) * 0.02 +
                        smoothstep(0.90, 0.97, arc2) * 0.015;

    // Iridescence — subtle rainbow sheen on the lit vinyl ring. The
    // three sin terms at 120° phase offsets (0, 2π/3 ≈ 2.094,
    // 4π/3 ≈ 4.189) produce an RGB shift that makes the vinyl look
    // like a real record catching the key light, not a flat black
    // disc. Masked by NdotL so it only shows on the lit side, and
    // by the two dist smoothsteps so it stays inside the vinyl ring.
    // Only contributes on the vinyl body (dist > labelR + 0.02), so
    // computing it here is safe — the label early-out never reaches
    // this line, and in the transition zone iriMask ≈ 0.
    float iriPhase = dist * 70.0 + angleLocal * 0.15 + r1 * 20.0;
    float3 iri = float3(
        sin(iriPhase) * 0.008,
        sin(iriPhase + 2.094) * 0.008,
        sin(iriPhase + 4.189) * 0.008
    );
    float iriMask = pow(max(0.0, NdotL), 1.5) *
                    smoothstep(labelR + 0.02, labelR + 0.12, dist) *
                    smoothstep(0.98, 0.75, dist);
    iri *= iriMask;

    // Vinyl body composite — dark base + grooves + scratches + lighting
    float3 vinyl = float3(0.018, 0.018, 0.022);
    vinyl *= grooveMod * radialDetail;
    vinyl += wornScratch;
    vinyl += anisoSpec;
    vinyl += broadShine;
    vinyl += tightSpec;
    vinyl += iri;
    vinyl += rim * 0.05;

    // ══════════════════════════════════════════════════════════════
    // ② PURE VINYL EARLY-OUT — dist >= labelR + 0.004 (~82% of pixels)
    // ══════════════════════════════════════════════════════════════
    if (dist >= labelR + 0.004) {
        float luma2 = dot(vinyl, float3(0.2126, 0.7152, 0.0722));
        vinyl = mix(float3(luma2), vinyl, mix(0.35, 1.0, hoverActive));
        vinyl += mix(-0.04, 0.0, hoverActive);
        return half4(half3(vinyl), half(edge));
    }

    // ══════════════════════════════════════════════════════════════
    // TRANSITION ZONE — blend vinyl into label across ~1% annulus
    // ══════════════════════════════════════════════════════════════

    float label = smoothstep(labelR + 0.004, labelR - 0.004, dist);
    float labelEdge = smoothstep(labelR + 0.004, labelR, dist) *
                      smoothstep(labelR - 0.015, labelR - 0.004, dist);

    // Label color (duplicated from the label early-out, kept local to
    // this narrow branch rather than computing unconditionally).
    float3 labelCol = float3(labelColor.rgb);
    float labelGrad = smoothstep(labelR, holeR + 0.03, dist);
    labelCol *= mix(0.65, 1.0, labelGrad);

    float paperGrain = sin(angleLocal * 200.0 + dist * 500.0 + r1 * 100.0) * 0.02 + 0.98;
    labelCol *= paperGrain;

    float innerCircle1 = smoothstep(0.22, 0.215, dist) * smoothstep(0.19, 0.195, dist);
    float innerCircle2 = smoothstep(0.14, 0.135, dist) * smoothstep(0.10, 0.105, dist);
    labelCol = mix(labelCol, labelCol * 0.85, innerCircle1 * 0.4);
    labelCol = mix(labelCol, float3(accentColor.rgb) * 0.9, innerCircle2 * 0.15);
    labelCol = mix(labelCol, float3(0.08, 0.02, 0.02), labelEdge * 0.5);

    float labelLight = pow(max(0.0, NdotL), 3.0) * 0.03;
    labelCol += labelLight;

    // Blend vinyl into label across the transition annulus
    float3 color = mix(vinyl, labelCol, label);

    // Shader-side desaturation + brightness dim replaces the SwiftUI
    // .saturation() and .brightness() CIFilter modifiers that were
    // running per-frame on EVERY card in the grid (2,880 CIFilter
    // ops/sec for 24 visible cards). hoverActive drives the blend:
    //   0.0 → desaturated (0.15 saturation) + dimmed (-0.12 brightness)
    //   1.0 → full color, full brightness
    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    float sat = mix(0.35, 1.0, hoverActive);
    color = mix(float3(luma), color, sat);
    float bright = mix(-0.04, 0.0, hoverActive);
    color += bright;

    return half4(half3(color), half(edge));
}
