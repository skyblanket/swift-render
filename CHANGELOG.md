# Changelog

## Unreleased

- LaunchFilm2, StyleReel, StyleReelVertical now score themselves in Swift —
  the Python soundtrack sidecars (make_launch/reel/kinetic_audio.py) are gone

- **Sound, in Swift** — `Score` DSL (`soundtrack(duration:)` on every scene
  protocol): kicks/claps/hats/crashes/bass/risers/booms/drones/whooshes with
  pattern helpers (fourOnFloor, hatSixteenths, bassline) and anchor placement
  (`crashes(at: chapters)`) so cuts and hits share one source of truth.
  Deterministic pure-Swift synth (vDSP), two-bus sidechain master, auto-mux —
  `render <Scene>` needs no --audio. `audio <Scene>` exports the WAV.
  In-memory FFT path: audio-reactive scenes react to their own score.

- `RenderContext` environment value — scenes can read render size/fps/duration
  (`@Environment(\.renderContext)`) and adapt layout per aspect

- MetalCompilerPlugin: .metal files now compile automatically at build time —
  checked-in metallib and manual tools/build_shaders.sh step are gone

- StyleReel + StyleReelVertical (9:16) — 12-aesthetic showcase scenes with
  card-zoom transitions + tools/make_reel_audio.py

- `contact <Scene> --cols 5 --rows 3` — labelled grid contact sheet PNG
  (full-size layouts downscaled, last sample lands before the end fade)
- `LaunchFilm` scene (57.5s launch film) + `tools/make_launch_audio.py`
  soundtrack engine (two-bus sidechain) + `tools/mix_vo.py` VO mixer
- Mono.metal studio shader pack: metaballs, inkFlow, interference,
  voronoiInk, monoTunnel (designed palettes)

## 0.5.0 — 2026-06-10

First release cut with the full "beat Remotion" API surface.

### Added
- **Timeline API** — `Timeline(t) { Clip(…) }` result-builder sequencing with
  local-time remapping, pinned overlay clips (`Clip(at:for:)`), and
  cross-transitions (`.cut`, `.fade`, `.slide`, `.flash`, `.overlap`).
- **Analytic springs** — closed-form damped `Spring` (under/critical/overdamped)
  evaluated at any `t`, plus `easeOutBack`, `elastic`, `bounce`, `expo`,
  and CSS-style `cubicBezier`.
- **Audio-reactive scenes** — `--audio` pre-analyzes the file (FFT) into RMS +
  bass/mid/high envelopes; scenes read `audio.band(.bass, at: t)` as pure,
  deterministic lookups. WAV/AIFF/AAC/M4A inputs.
- **JSON props** — `PropsScene`/`PropsAudioScene` protocols,
  `swift-render props <Scene>` template printing, `--props file.json`.
- **CLI** — `frame <Scene> --at <t>` single-PNG export, `render --range a:b`
  partial renders, `--no-postfx`, `--version`; unknown flags now error.
- **Library product** — `import SwiftRender` from your own package; the CLI is
  a thin wrapper. Test suite (determinism, springs, easing, timeline, audio)
  + GitHub Actions CI.
- `tools/build_shaders.sh` + a loud runtime warning when `.metal` sources are
  newer than the bundled `default.metallib`.

### Fixed
- Flickering grain-free strip on frame edges (PostFX tile offset overscan).
- Film-grain noise tile now seeded — frames are byte-identical across runs.
- `PostFX` no longer doubles when a scene applies its own (`ownsPostFX`).
- Kinetic marquee covers the full frame; galaxy shader stars are round points.

### Scenes
- New: `Kinetic`, `JustRenderIt` (+ `tools/make_jri_audio.py` beat track),
  `AudioBars` (audio + props reference), `TimelineDemo` (Timeline reference).
