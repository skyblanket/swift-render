# Changelog

## 0.9.0 — 2026-10-06

### Added
- **`render --jobs n|auto`** — parallel rendering across processes, stitched by the new
  `MP4Assembler` without re-encoding; frame-exact against a single-process render
  (StyleLab 41 s 1080p60: 65 s → 19 s at 5 jobs).
- **`VisionTrack`** — Apple Vision body pose, hand pose and person masks per frame, analyzed
  once and cached; `PoseOverlay`; `Rotoscope` demo scene (PropsScene: clip + Stylize look).
- **`swift-render smoke`** — one frame of every scene plus a no-swish check; runs in CI.
- **`check` voice vs music** — dB the voiceover sits above the ducked music while speaking,
  with buried time spans.
- `Bundle.swiftRender`, `ShaderLibrary.swiftRender`, public `PostFX.init`.
- `NeverHeard` — a 93 s first-person short narrated with local TTS (Kokoro, `say` fallback).
- `SlipDueLaunch` — 28 s vertical launch spot.
- `Release090` — a 40 s narrated tour of this release.

### Changed
- Demo scenes moved to a separate **`SwiftRenderScenes`** target/product — the library no
  longer compiles them. The registry plugin scans both targets.
- Voiceover has its own mixer bus; kicks/booms/samples now duck ~4.5 dB under speech.
- The recorder's audio mux copies the video stream (was a full re-encode); encoder writes no
  B-frames so frame 0 sits at t=0.
- `whoosh` / `riser` are deprecated and removed from every scene. Rebalanced voice levels in
  SlipDueLaunch (voice was 5.8 dB under the music), MediaDemo and NeverHeard.

### Removed
- JETRAY scenes and their assets (`assets/seeker`, `assets/plate`, `data/`) — 64 MB.

### Fixed
- `--range` passed the range end as the scene's duration (wrong fades/timing) and gave
  audio-reactive scenes silence; frame times now come from absolute frame indices.
- Shader count corrected to 22 everywhere (README said 12, Sizzle and the quickstart said 23).


## 0.8.1 — 2026-10-02

### Added
- **Transition marks** — clean, noise-free alternatives to swish transitions:
  `tick(at:)` (woodblock click), `rim(at:)` (mid knock), `thump(at:)` (soft low hit),
  `blip(note, at:)` (pure sine), `swell(note, at:, duration:)` and
  `swell(chord, into: t, duration:)` (a pitched build that stops on the downbeat).
- `check` warns when a score uses noise sweeps (`whoosh`/`riser`).

### Changed
- **House rule: no swish transitions.** `StyleLab` drops its per-cut whooshes and replaces its
  risers with chord swells. `whoosh`/`riser` remain in the API for existing scenes, but new
  scenes should mark cuts with the music or the transition marks above.

## 0.8.0 — 2026-10-02

### Added
- **Samples in the Score** — `sample(path, at:, amp:, pan:, rate:, offset:, duration:)` plays any
  wav/aiff/caf/m4a/mp3 or the audio track of an mp4/mov. Decoded once to 44.1 kHz stereo and
  cached; routed around the kick duck. `samples(path, at: [t])` for anchors.
- **Voiceover** — `speak("…", at: t, engine: .say(voice:wpm:) | .kokoro(voice:))`. Lines are
  synthesized locally on first use and cached by content hash (`~/Library/Caches/swift-render/tts`),
  so renders stay deterministic. The music bus ducks ~6 dB under speech.
- **Captions** — `CaptionTrack(score)` builds timed cues from the `speak` lines (voiced span of
  the rendered audio, word timing by length + punctuation, balanced line splits);
  `CaptionView(track, at: t)` burns them in with a karaoke highlight;
  `swift-render captions <Scene> --out x.srt|.vtt` exports a sidecar.
- **Video & image clips** — `VideoClip(path, at:, rate:, offset:, loop:, contentMode:)` with
  zero-tolerance frame decode; `ImageClip(path)`; `MediaLibrary` for raw frames/durations;
  `AssetPaths` resolves scene paths (cwd, assets/, package root).
- **`swift-render preview <Scene>`** — live window: scrubber, play/pause (space), frame-step (←/→,
  ⇧ for 1 s), timecode/frame readout, synced audio. `--snapshot out.png` captures the window and exits.
- `crackle(from:to:)` vinyl bed voice; `ScoreSynth.render(_:normalize:)` for un-normalized stems.
- `RenderFrame` — the one frame wrapper (size, render context, PostFX) shared by recorder,
  PNG frames and preview.
- `check` reports samples (and missing files) and voiceover (lines, seconds, caption cues).
- `scripts/typecheck-budget.sh` + CI step — flags expressions/functions slow to type-check
  before CI's older compiler rejects them.
- `MediaDemo` scene; `assets/demo/clip.mp4`; tests for samples, captions, voiceover, video frames.

### Changed
- `OpenEarLaunch` carries its foley in its own Score (`assets/openear-foley`) —
  `tools/openear_launch_mix.py` is gone; `check` now reports the real mix.
- Split the four slowest type-check spots (Kinetic, KineticType, LaunchFilm).

## 0.7.0 — 2026-10-02

- `PixelGrid` (sample any view to an RGBA grid) and `Stylize` — 16 deterministic whole-frame
  renderers (pixel, dither, gameBoy, ascii, halftone, cmyk, mosaic, led, engraving, crosshatch,
  pointillism, bricks, crossStitch, lowPoly, blueprint, thermal); `StyleLab` demo reel.

## 0.6.0 — 2026-10-02

- Scene registry generated at build time (SceneRegistryPlugin) — no hand-edited dictionary.
- MetalCompilerPlugin falls back to `Shaders/prebuilt.metallib` without the Metal toolchain.
- CLI: `new`, `check`, `frame --at a,b,c`, `render --preview --open`; contact sheets sample shot midpoints.
- `Music.swift` (notes, chords, scales, instruments, phrases); `Dither`, `PixelCanvas`, `PixelFont`.
- PostFX opaque base; CI on macos-15.

## Earlier, between 0.5.0 and 0.6.0

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
