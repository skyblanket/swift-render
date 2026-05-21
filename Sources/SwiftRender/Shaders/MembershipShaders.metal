#include <metal_stdlib>
using namespace metal;

// =====================================================================
//  MembershipShaders.metal
//  OpenEar — "You're in" onboarding celebration
//
//  Three stitchable SwiftUI shaders:
//    • foilShader      — iridescent holographic foil for the card surface
//    • backdropShader  — ambient dark gradient + grain for the full screen
//    • sleeveShader    — glossy black vinyl record jacket with specular tracking
//
//  Integration matches VinylDisc.metal: [[ stitchable ]] entry points
//  reached via ShaderLibrary.<functionName>(...) from SwiftUI.
// =====================================================================


// ─────────────────────────────────────────────────────────────────────
//  SHARED HELPERS
// ─────────────────────────────────────────────────────────────────────

// Cheap 2D hash — used for grain. Single MAD + sin + fract.
// Good enough for visual grain, no need for a proper PRNG.
static inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

// 1D hash — matches VinylDisc.metal. Used for frozen-seed randomisation.
static inline float hash(float n) {
    return fract(sin(n) * 43758.5453123);
}

// Value noise — smooth 2D noise by bilerping a hash grid.
// Cheaper than gradient noise, plenty for a 5% opacity grain layer.
static inline float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);   // smoothstep

    float a = hash21(i + float2(0.0, 0.0));
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));

    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Spectral palette — Iñigo Quílez cosine gradient.
// Maps a scalar t (any real) → a subtle, desaturated metallic band.
// Params tuned for dark-silver-to-gunmetal shimmer with faint cool edge hints.
static inline float3 spectrum(float t) {
    const float3 a = float3(0.20, 0.20, 0.22);  // base offset — sits near black
    const float3 b = float3(0.15, 0.12, 0.18);  // amplitude  — narrow shimmer
    const float3 c = float3(1.00, 1.00, 1.00);  // frequency
    const float3 d = float3(0.00, 0.33, 0.67);  // phase — hue wheel
    return a + b * cos(6.28318 * (c * t + d));
}

// Soft luminance for energy-conserving blend decisions.
static inline float luma(float3 c) {
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}




// =====================================================================
//  SHADER 1 — foilShader
//
//  Iridescent holographic foil laid on top of the membership card.
//  Physically inspired by thin-film interference: the wavelength that
//  constructively interferes depends on the view angle and the film's
//  optical path length. We fake the optical path with a diagonal phase
//  ramp across the card.
//
//  Frozen-seed pattern (matching VinylDisc.metal): the base iridescent
//  pattern is derived from a single `seed` float via the 1D hash helper,
//  so each card gets a unique holographic look. The `mouseNorm` input
//  shifts the hue bands and specular sweep on top of the seed — like
//  tilting a physical holographic card under a light. No time parameter;
//  the only dynamic input is the cursor position.
//
//  Usage: .colorEffect(ShaderLibrary.foilShader(...))
//  The modifier passes the card's rendered color as `currentColor`;
//  we multiply/screen the iridescent layer on top of it so the card's
//  text and dark substrate remain legible.
//
//  Args (after the implicit position/color pair):
//    size        — view size in points (float2)
//    seed        — unique float per card instance (drives all randomness)
//    mouseNorm   — normalized cursor position (0-1 in both axes); centre
//                  (0.5, 0.5) gives the same look as the old frozen shader
//    intensity   — 0 disables foil, 1 = full strength
// =====================================================================

[[ stitchable ]]
half4 foilShader(
    float2 position,
    half4 currentColor,
    float2 size,
    float seed,
    float2 mouseNorm,
    float intensity
) {
    // Early out on fully transparent pixels — the card is a rounded rect,
    // so the corners outside the mask have zero alpha. Don't decorate them.
    if (currentColor.a < 0.001h) {
        return currentColor;
    }

    // Normalize to [0,1] card space then to centered [-1,1].
    float2 uv      = position / size;
    float2 centred = uv * 2.0 - 1.0;

    // Correct aspect so the foil bands don't stretch on the 400x260 card.
    float aspect = size.x / max(size.y, 1.0);
    centred.x *= aspect;

    // ── Mouse-derived tilt ──
    // Map mouseNorm (0-1) to signed range (-1..1). At centre (0.5, 0.5)
    // tilt is zero and the shader matches the old frozen appearance.
    // The tiny epsilon avoids a degenerate zero-vector when normalizing.
    float2 tilt = mouseNorm * 2.0 - 1.0;
    float2 tiltSafe = tilt + 0.001;

    // ── Unique randomisation per card (frozen-seed pattern) ──
    float r1 = hash(seed);
    float r2 = hash(seed + 1.0);
    float r3 = hash(seed + 2.0);
    float r4 = hash(seed + 3.0);

    // ── Iridescent phase ──
    // Diagonal band across the card — 2.2 controls band count.
    // r1 sets the phase offset, r2 adds a view-angle proxy tilt.
    //
    // Mouse influence: a directional dot-product shifts the phase across
    // the card surface, simulating the way real thin-film interference
    // changes as the viewing angle moves. Scaled by 0.3 so the seed-
    // derived base pattern remains dominant.
    float mousePhase = dot(centred, normalize(tiltSafe)) * 0.3;

    float phase =
        (centred.x * 0.55 + centred.y * 0.65) * 2.2  // diagonal gradient
      + r1 * 6.28                                     // seed-driven phase offset
      + r2 * 0.45                                     // seed-driven tilt proxy
      + mousePhase;                                   // cursor-driven shift

    // A second, slower phase layer for subtle multi-band interference.
    // Uses the perpendicular of tiltSafe for visual separation.
    float mousePhase2 = dot(centred, normalize(float2(-tiltSafe.y, tiltSafe.x))) * 0.2;

    float phase2 =
        (centred.x * -0.3 + centred.y * 0.9) * 1.4
      + r3 * 6.28
      - r4 * 0.25
      + mousePhase2;

    float3 hueA = spectrum(phase);
    float3 hueB = spectrum(phase2 + 0.15);

    // Mix the two bands — hueB rides on top at lower amplitude, creating
    // the shimmering "double rainbow" feel of real holographic foil.
    float3 foil = mix(hueA, hueB, 0.35);

    // ── Specular sweep ──
    // A soft Gaussian highlight whose position and direction respond to
    // the cursor. The seed still provides the base placement; tilt nudges
    // the sweep centre toward the mouse and blends the sweep direction
    // partially toward the tilt vector — like tilting a holographic card
    // under a fixed overhead light.
    float2 seedDir   = float2(cos(r1 * 6.28), sin(r2 * 6.28)) + float2(0.2, 0.1);
    float2 sweepDir  = normalize(mix(seedDir, tiltSafe, 0.35));
    float sweepCoord = dot(centred, sweepDir);
    float sweepCtr   = r3 * 0.4 + tilt.x * 0.3;
    float sweep      = exp(-pow(sweepCoord - sweepCtr, 2.0) * 2.8);
    foil += sweep * 0.35;

    // ── Fresnel-ish edge boost ──
    // Grazing angles (near the card edge in centred space) get a brighter
    // foil response — mimics how holographic stickers flare at the rim.
    float edgeD     = length(centred);
    float fresnel   = pow(clamp(edgeD * 0.72, 0.0, 1.0), 2.5);
    foil *= (1.0 + fresnel * 0.4);

    // ── Brushed metal grain — fine horizontal striations ──
    // Real brushed metal has directional micro-grooves from the polishing
    // process. We simulate two frequencies: a primary grain and a finer
    // harmonic offset slightly in X to avoid perfect regularity.
    // brushFreq varies per card via r1 so each instance feels unique.
    float brushFreq = 800.0 + r1 * 200.0;
    float brush     = sin(centred.y * brushFreq + r2 * 100.0) * 0.5 + 0.5;
    float brushFine = sin(centred.y * brushFreq * 3.7 + centred.x * 40.0) * 0.5 + 0.5;
    float brushTex  = 0.92 + brush * 0.05 + brushFine * 0.03;
    foil *= brushTex;

    // ── Surface micro-roughness ──
    // Breaks up the perfectly smooth gradient with per-pixel noise,
    // giving the surface a machined/physical quality under close
    // inspection. Very subtle: ±2% brightness variation.
    float microNoise = hash21(position * 2.0 + seed) - 0.5;
    foil += microNoise * 0.04;

    // ── Anisotropic specular highlight ──
    // When light hits brushed metal, the directional grooves scatter
    // the reflection into a band perpendicular to the grain direction
    // (Kajiya-Kay model simplified). We compute the tangent-light dot
    // product and use (1 - TdotL^2) raised to a power to get the
    // characteristic stretched highlight. The light direction tracks
    // the cursor slightly so the highlight responds to tilt.
    float2 brushDir  = float2(1.0, 0.0);
    float2 lightDir  = normalize(float2(-0.6, -0.8) + tilt * 0.3);
    float TdotL      = dot(brushDir, lightDir);
    float anisoSpec   = pow(1.0 - TdotL * TdotL, 6.0) * 0.08;
    anisoSpec        *= smoothstep(1.2, 0.4, edgeD);
    foil += anisoSpec;

    // ── Intensity & legibility ──
    // Scale final amplitude so the foil modulates the card rather than
    // dominating it. The underlying text is drawn by SwiftUI in the
    // existing color; we screen-blend the foil contribution on top.
    float amp = clamp(intensity, 0.0, 1.0) * 0.22;

    // Energy conservation: don't let foil push luminance above ~0.85
    // relative strength. Darken very bright spectrum values before mixing.
    foil = min(foil, float3(0.92));

    // ── Blend with card ──
    // Screen blend: 1 - (1-a)*(1-b) — additive but soft-clamped.
    // Multiplied by the card's own alpha so the rounded corners are
    // respected automatically.
    float3 base     = float3(currentColor.rgb);
    float3 screened = 1.0 - (1.0 - base) * (1.0 - foil * amp);

    // Mix back toward base in the darkest areas of the card so heavy
    // shadows don't get washed out. `luma` keeps this perceptual.
    float keepDark  = smoothstep(0.02, 0.18, luma(base));
    float3 outRGB   = mix(base, screened, keepDark);

    return half4(half3(outRGB), currentColor.a);
}


// =====================================================================
//  SHADER 2 — backdropShader
//
//  Full-screen ambient wallpaper for the "You're in" celebration screen.
//  Matches the app's jet-black design language — the same near-invisible
//  radial warmth used by WelcomeView and PermissionsView, stepped up
//  just slightly for the celebration moment.
//
//  Three layers:
//    1. Jet-black base with a single slow-breathing warm radial glow.
//    2. A faint secondary bloom that drifts slowly, giving the tiniest
//       bit of life vs the static screens. Both blooms are at the same
//       intensity as the paywall's Color.red.opacity(0.08).
//    3. Film grain for analog texture.
//
//  The album sleeve + vinyl disc IS the visual hero. The backdrop is
//  barely there — just enough warmth to not be flat black.
//
//  Usage: .colorEffect(ShaderLibrary.backdropShader(...))
//  Applied to a black Rectangle() filling the 960x669 window.
//
//  Args:
//    size         — view size in points
//    time         — seconds elapsed
//    reduceMotion — 0 or 1; freezes all animation when 1
// =====================================================================

[[ stitchable ]]
half4 backdropShader(
    float2 position,
    half4 currentColor,
    float2 size,
    float time,
    float reduceMotion
) {
    float2 uv      = position / size;
    float2 centred  = uv * 2.0 - 1.0;

    float aspect = size.x / max(size.y, 1.0);
    centred.x *= aspect;

    float motion = 1.0 - clamp(reduceMotion, 0.0, 1.0);
    float t      = time * motion;

    // Base — near-black, matching OEColor.base (#000) with a whisper
    // of warmth to prevent banding on HDR displays.
    float3 color = float3(0.005, 0.004, 0.004);

    float r = length(centred);

    // Primary glow — very subtle warm centre.
    float glow = exp(-r * r * 1.5);
    float breathe = 0.90 + 0.10 * sin(t * 0.08);
    color += float3(0.04, 0.010, 0.007) * glow * breathe;

    // Secondary bloom — barely visible drift.
    float2 driftCentre = float2(
        sin(t * 0.04) * 0.30,
        cos(t * 0.03) * 0.22
    );
    float driftD = length(centred - driftCentre);
    float drift  = exp(-driftD * driftD * 1.0);
    drift *= 0.90 + 0.10 * sin(t * 0.06 + 1.2);
    color += float3(0.025, 0.007, 0.005) * drift;

    // Vignette — gentle radial darkening matching the other
    // onboarding screens' RadialGradient(startRadius: 100, endRadius: 480)
    // feel. Not aggressive — the base is already so dark that
    // heavy vignetting would make the edges indistinguishable from black.
    float vig = 1.0 - smoothstep(0.6, 1.5, r);
    color *= mix(0.65, 1.0, vig);

    // Film grain — heavy analog texture, visible noise.
    // Coarse grain — slow-crawling noise for organic movement
    float2 grainUV = position * 0.9 + float2(t * 13.0, t * -7.0);
    float g = valueNoise(grainUV) - 0.5;
    color += g * 0.06;

    // Fine grain — per-pixel static for film feel
    float gFine = hash21(position + floor(t * 24.0)) - 0.5;
    color += gFine * 0.03;

    // Mottled patches — large slow-moving noise clouds
    float2 patchUV = position * 0.003 + float2(t * 0.8, t * -0.5);
    float patch = valueNoise(patchUV) - 0.5;
    color += patch * 0.04;

    // Mid-frequency texture — visible paper-like grain
    float midGrain = valueNoise(position * 0.15 + float2(t * 2.0, 0.0)) - 0.5;
    color += midGrain * 0.035;

    color = max(color, 0.012);

    return half4(half3(color), 1.0h);
}


// =====================================================================
//  SHADER 3 — sleeveShader
//
//  Glossy black vinyl record sleeve / jacket. The kind of premium
//  gatefold cover you'd find in a high-end pressing: nearly jet-black,
//  semi-gloss card stock, catching warm overhead light with a broad
//  specular bloom that tracks the cursor.
//
//  Light physics at play:
//    • Primary specular — a large Gaussian blob simulating a single
//      warm overhead source reflected off the glossy card surface.
//      Position is biased upper-left by default and tracks mouseNorm.
//    • Fill light — a much fainter counter-highlight from the lower-
//      right to prevent the sleeve from reading totally flat.
//    • Vignette — edge darkening via a radial falloff, mimicking how
//      a glossy planar surface reflects less at oblique viewing angles
//      (simplified Fresnel).
//    • Edge glint — the outermost rim of the sleeve catches a faint
//      bright line, like the bevelled edge of a card under light.
//    • Surface grain — per-pixel card-stock micro-texture via hash21
//      at very low amplitude to break up smooth gradients.
//
//  Usage: .colorEffect(ShaderLibrary.sleeveShader(...))
//  Applied to a Rectangle().fill(.black) at ~320x320 pt.
//
//  Args:
//    size        — view size in points
//    seed        — unique float per card (drives noise variation)
//    mouseNorm   — normalised cursor position (0-1); (0.5,0.5) = rest
//    glossiness  — 0-1, scales specular intensity
// =====================================================================

// ─────────────────────────────────────────────────────────────────────
//  Sleeve helpers
// ─────────────────────────────────────────────────────────────────────

// Anisotropic specular highlight — elliptical Gaussian stretched along
// a principal axis.  `axisDir` is the unit direction of the major axis,
// `sigmaA` is the spread along it (large = elongated), `sigmaB` is the
// spread across it (small = narrow).  The result approximates how light
// reflects off a glossy planar surface: the reflection stretches in the
// direction perpendicular to the viewing tilt, because the reflected
// image of a point light source is elongated by the surface curvature /
// viewing angle — the "stretched highlight" you see on a credit card.
static inline float anisotropicGaussian(float2 p, float2 centre,
                                         float2 axisDir,
                                         float sigmaA, float sigmaB) {
    float2 d = p - centre;
    // Project d onto the major and minor axes.
    float projA = dot(d, axisDir);                        // along stretch
    float projB = dot(d, float2(-axisDir.y, axisDir.x));  // perpendicular
    float exponent = (projA * projA) / (2.0 * sigmaA * sigmaA)
                   + (projB * projB) / (2.0 * sigmaB * sigmaB);
    return exp(-exponent);
}

// Subtle chromatic fringe / rainbow edge — thin-film-like iridescence
// at the boundary of a specular highlight.  Returns an RGB colour whose
// hue cycles through the visible spectrum based on the radial distance
// from the specular centre.  The fringe only appears in a narrow annular
// band around the highlight edge, simulating how white light diffracts
// at the boundary of a glossy surface reflection.
static inline float3 specularFringe(float specularValue, float dist,
                                     float fringeRadius, float fringeWidth) {
    // Band-pass: peaks when dist ≈ fringeRadius, falls off either side.
    float band = exp(-pow((dist - fringeRadius) / max(fringeWidth, 0.001), 2.0));
    // Hue based on angular distance — full spectrum cycle across the band.
    float hue = dist * 12.0;  // spatial frequency of the rainbow
    float3 rainbow = 0.5 + 0.5 * cos(6.28318 * (hue + float3(0.0, 0.33, 0.67)));
    // Only visible at the edge of the specular, not in the bright centre.
    float edgeMask = smoothstep(0.5, 0.15, specularValue);
    return rainbow * band * edgeMask;
}

// Radial vignette — 1.0 at the centre, darkens toward the edges.
// `strength` controls how aggressively the edges darken (higher = darker).
static inline float vignette(float2 uv, float strength) {
    // uv expected in [0,1] space.
    float2 centred = uv - 0.5;
    float d = length(centred) * 2.0;   // 0 at centre, ~1.41 at corners
    return 1.0 - pow(clamp(d, 0.0, 1.0), strength);
}

[[ stitchable ]]
half4 sleeveShader(
    float2 position,
    half4 currentColor,
    float2 size,
    float seed,
    float2 mouseNorm,    // 0-1 normalised cursor position
    float glossiness     // 0-1, specular intensity scale
) {
    // Early out for transparent pixels (rounded-rect mask corners).
    if (currentColor.a < 0.001h) {
        return currentColor;
    }

    // ── Coordinate setup ──
    // uv: 0-1 across the sleeve. centred: -1..1 for radial effects.
    float2 uv      = position / size;
    float2 centred  = uv * 2.0 - 1.0;
    float aspect    = size.x / max(size.y, 1.0);
    centred.x *= aspect;

    // Per-sleeve randomisation — subtle variation in grain and highlight shape.
    float r1 = hash(seed);
    float r2 = hash(seed + 1.0);

    // ═══════════════════════════════════════════
    //  BASE COLOUR
    //
    //  Very dark grey, not pure black. A tiny warm
    //  shift (blue channel slightly higher than red)
    //  gives the ink-black look of quality card stock.
    // ═══════════════════════════════════════════

    float3 color = float3(0.04, 0.04, 0.045);

    // ═══════════════════════════════════════════
    //  PRIMARY SPECULAR — anisotropic glossy card reflection
    //
    //  When light reflects off a flat glossy surface (credit card,
    //  record sleeve), the specular highlight stretches into an
    //  elongated ellipse.  The stretch direction is perpendicular
    //  to the tilt — when you tilt a card left-right, the highlight
    //  elongates vertically.  This is because the reflected image of
    //  the point source is compressed along the tilt axis by the
    //  foreshortened surface normal.
    //
    //  We compute the tilt vector from the cursor position, derive
    //  the stretch axis, and render an anisotropic Gaussian.  A
    //  secondary wider/softer lobe sits underneath for the broad
    //  ambient reflection, and a subtle rainbow fringe appears at
    //  the highlight boundary (thin-film diffraction on glossy
    //  coatings).
    // ═══════════════════════════════════════════

    float gloss = clamp(glossiness, 0.0, 1.0);

    // Map mouse to centred-space (-1..1).
    float2 specCentre = (mouseNorm * 2.0 - 1.0);

    // ── Natural ambient light ──
    // Instead of a sharp geometric spot, layer three soft Gaussians
    // at different scales to mimic how overhead light wraps around a
    // glossy card surface. The cursor shifts all three together.

    float3 specColor = float3(1.0, 0.97, 0.92);

    // Layer 1: Broad ambient wash — very wide, very subtle.
    // Like the room's general light hitting the surface.
    float2 d1 = centred - specCentre * 0.6;
    float ambient = exp(-dot(d1, d1) / (2.0 * 0.55 * 0.55));
    color += specColor * ambient * 0.03 * gloss;

    // Layer 2: Mid-range glow — the main visible highlight.
    // Softer than a point source, more like a large window reflection.
    float2 d2 = centred - specCentre * 0.85;
    float midGlow = exp(-dot(d2, d2) / (2.0 * 0.25 * 0.25));
    color += specColor * midGlow * 0.08 * gloss;

    // Layer 3: Focused core — small bright center for realism.
    // Sits exactly at the cursor for direct feedback.
    float2 d3 = centred - specCentre;
    float core = exp(-dot(d3, d3) / (2.0 * 0.12 * 0.12));
    color += specColor * core * 0.06 * gloss;

    // Subtle warm fringe at the edge of the mid glow
    float fringeDist = length(d2) / 0.25;
    float fringeBand = exp(-pow(fringeDist - 1.3, 2.0) * 4.0);
    float3 warmFringe = float3(1.0, 0.92, 0.85) * fringeBand * 0.012 * gloss;
    color += warmFringe;

    // ═══════════════════════════════════════════
    //  SECONDARY FILL LIGHT — lower-right
    //
    //  A much broader, fainter counter-light that
    //  lifts the opposite corner just enough to
    //  prevent the sleeve from looking like a flat
    //  black rectangle. Simulates ambient bounce.
    // ═══════════════════════════════════════════

    // Fill light removed — single light source only.

    // ═══════════════════════════════════════════
    //  EDGE DARKENING — vignette
    //
    //  Glossy surfaces reflect less light at oblique
    //  viewing angles (Fresnel effect). We approximate
    //  this with a radial vignette: the edges of the
    //  sleeve receive less of the ambient light.
    //  Strength of 2.2 gives a gentle, natural roll-off.
    // ═══════════════════════════════════════════

    float vig = vignette(uv, 2.6);
    // Blend: darken edges to reinforce the "holding a black card" feel.
    // Mix from 0.82 to 1.0 so the vignette removes ~18% brightness at the corners.
    color *= mix(0.82, 1.0, vig);

    // ═══════════════════════════════════════════
    //  SURFACE GRAIN — card-stock micro-texture
    //
    //  Fine per-pixel noise at very low amplitude
    //  breaks the smooth gradients and gives the
    //  surface a tactile, physical feel. This is the
    //  texture of printed card stock, not brushed metal.
    //  Amplitude boosted for visible card-stock texture.
    // ═══════════════════════════════════════════

    // Coarse grain — visible paper/card texture
    float grain = hash21(position * 1.5 + seed + r2 * 100.0) - 0.5;
    color += grain * 0.045;

    // Fine grain — secondary layer for organic feel
    float grainFine = hash21(position * 3.0 + seed * 2.0 + 77.0) - 0.5;
    color += grainFine * 0.025;

    // Low-frequency noise — broad mottled patches like aged card stock
    float mottle = valueNoise(position * 0.008 + seed * 10.0) - 0.5;
    color += mottle * 0.03;

    // Subtle vertical gradient — slightly lighter at top, simulates
    // overhead ambient light hitting the flat surface
    float topLight = smoothstep(1.0, 0.0, uv.y) * 0.025;
    color += topLight;

    // ═══════════════════════════════════════════
    //  FRESNEL EDGE GLINT
    //
    //  At the very rim of a glossy card, light catches
    //  the bevelled edge and creates a thin bright line.
    //  We detect the outermost ~5% of the surface in
    //  UV space and add a faint bright stroke.
    //
    //  The effect uses the distance from each edge
    //  independently (not radial) so it traces the
    //  rectangular perimeter of the sleeve.
    // ═══════════════════════════════════════════

    // Distance from the nearest edge in 0-1 UV space.
    float edgeDistX = min(uv.x, 1.0 - uv.x);
    float edgeDistY = min(uv.y, 1.0 - uv.y);
    float edgeDist  = min(edgeDistX, edgeDistY);

    // The glint lives in the 0-5% strip near the edge.
    // smoothstep ramps it from zero (at 5% inset) to full at the edge,
    // then a second smoothstep fades the very outermost pixel to avoid
    // a harsh clipped line.
    float edgeGlint = smoothstep(0.05, 0.015, edgeDist)
                    * smoothstep(0.0, 0.008, edgeDist);

    // Modulate by mouse-derived specular direction so the glint is
    // brighter on the side facing the light, dimmer on the shadow side.
    // This is the directional Fresnel component.
    float lightBias = 0.5 + 0.5 * dot(normalize(centred + 0.001),
                                        normalize(-specCentre + 0.001));

    // Edge glint disabled — clean edges preferred.
    // float glintBrightness = 0.04 * gloss * mix(0.4, 1.0, lightBias);
    // color += specColor * edgeGlint * glintBrightness;

    // ═══════════════════════════════════════════
    //  FINAL CLAMP
    //
    //  Grain can push values below zero; specular
    //  is capped well below 1.0 by design, but clamp
    //  both sides for safety.
    // ═══════════════════════════════════════════

    color = clamp(color, 0.0, 1.0);

    return half4(half3(color), currentColor.a);
}
