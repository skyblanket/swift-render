# Features

Detailed examples for the SwiftRender engine. Start with the [README](../README.md) for setup.

### Sequencing - `Timeline`

No segment math, no frame counting. Clips get **local time**; transitions overlap automatically; pinned clips float over everything:

```swift
Timeline(t) {
    Clip(2.2) { local in TitleCard(t: local) }
    Clip(2.4) { local in SpringShowcase(t: local) }.transition(.slide(0.45))
    Clip(2.4) { local in MetalMoment(t: local) }.transition(.flash())
    Clip(4.0) { local in Outro(t: local) }.transition(.fade(0.5))
    Clip(at: 0, for: 9.9) { local in ProgressHUD(t: local) }   // pinned overlay
}
```

https://github.com/skyblanket/swift-render/raw/main/docs/assets/timeline-demo.mp4

### Springs - closed-form, scrub-safe

`Spring` is solved **analytically** (under/critical/overdamped) - position at any `t` is computed directly, never integrated. Scrub to frame 4081 and get the exact same pixels, every run. Plus `easeOutBack`, `elastic`, `bounce`, `expo`, `cubicBezier(…)`.

### Audio-reactive - `--audio`

The file is FFT-analyzed **once** before rendering (RMS + bass/mid/high envelopes); scenes read it as a pure lookup, so determinism survives:

```swift
public struct AudioBars: PropsAudioScene {
    public static func body(at t: Double, duration: Double,
                            props: Props, audio: AudioTrack) -> some View {
        let bass = audio.band(.bass, at: t)        // 0…1
        // scale, glow, slam on the beat …
    }
}
```

https://github.com/skyblanket/swift-render/raw/main/docs/assets/audiobars.mp4

External audio can be supplied with `--audio`; scenes can also declare their own native Swift score. Keep both on the same edit timeline and review the exported mix.

### Data-driven - `--props`

```bash
swift run swift-render props AudioBars > p.json     # JSON template from the scene's defaults
swift run swift-render render AudioBars --props p.json --audio beat.wav
```

Pipe in JSON per record and render a thousand personalized variants - the AI/data-pipeline workflow Remotion's `inputProps` made popular, native.

## Sound, in Swift

Scenes declare their own soundtrack - same constants drive the cuts and the
hits, so audio/video sync is structural, not manual. The synth is pure Swift,
deterministic:

- **Drums & FX:** kick, clap, hat, crash, 808 boom, laser - two-bus sidechain pumping
- **Transition marks:** `tick`, `rim`, `thump`, `blip(note)`, `swell(note)` / `swell(chord, into:)` - tonal and noise-free. House rule: no swish transitions (`whoosh`/`riser` still exist for old scenes; `check` flags them)
- **Melodic voices:** `pluck` (kalimba-ish, with echo), `bell` (FM), `pad` (detuned, slow), `chip` (25% pulse), `triBass` (round triangle), `bass`, `drone`
- **Music theory:** note names (`.a3`, `.c5`, `Note.midi(64)`), `Chord.minor7(.a3)` & friends, `Scale.minorPentatonic.degree(i, root:)`
- **Phrases:** `chordPad`, `strum`, `arpeggio(…, pattern: .upDown)`, `melody([(beat, note)], start:, bpm:)`
- **Samples:** `sample("foley/click.wav", at: t, amp:, pan:, rate:)` - any wav/aiff/m4a/mp3 or the audio of an mp4/mov, decoded once and cached; `rate` varispeed keeps repeats from sounding identical
- **Voiceover:** `speak("…", at: t)` - local TTS (`say`, or Kokoro via `engine: .kokoro()`), cached by content hash so renders stay deterministic; the music ducks ~6 dB under it
- **Texture:** `crackle(from:to:)` - vinyl surface noise bed

```swift
public static func soundtrack(duration: Double) -> Score? {
    Score(duration: duration) {
        fourOnFloor(from: 2.4, to: 33.6)          // kicks + backbeat claps
        hatSixteenths(from: 2.4, to: 33.6)
        bassline([.a1, .a1, .c2, .g1], from: 2.4, to: 33.6)
        crashes(at: chapters)                      // the SAME array as the Timeline
        swell(.minor7(.a3), into: 36.0, duration: 2.4)        // pitched build, no noise sweep
        boom(at: 36.0)
        chordPad(.minor9(.a3), at: 0, duration: 4.8)                 // harmony, not just drums
        arpeggio(.minor7(.a4), from: 2.4, to: 9.6, step: 0.15, pattern: .upDown)
        melody([(0, .e5), (1, .g5), (2.5, .a5)], start: 9.6, bpm: 100, instrument: .bell)
    }
}
```

```bash
swift run swift-render render KineticType        # score synthesized + muxed, zero flags
swift run swift-render audio KineticType --out out/score.wav   # export the track alone
```

`--audio file` always wins over a scene's score. Audio-reactive scenes react
to their own synthesized score - declare the beat, and the visuals hear it.

## Real Metal shaders

Drop a `.metal` file in `Sources/SwiftRender/Shaders/` and `swift build` - shaders compile automatically (SwiftPM build plugin). Call them on any view:

```swift
Rectangle().fill(.black).colorEffect(
    ShaderLibrary.swiftRender.galaxy(.float2(1920, 1080), .float(Float(t)))
)
```

The included shaders cover `rimGlow`, `foilHolographic`, `plasmaField`, `chromaticAberration`, `audioBars`, `caustics`, `liquidMetal`, `kaleidoscope`, `truchet`, `galaxy`, `neonGrid`, `smokeFlow`, `warpTunnel` - plus the studio pack from the launch film: `metaballs` (raymarched chrome), `inkFlow`, `interference`, `voronoiInk`, `monoTunnel`:

https://github.com/skyblanket/swift-render/raw/main/docs/assets/shader-gallery.mp4

Recent Xcodes ship the Metal compiler as a separate download. Without it the build **doesn't fail**: the plugin falls back to the checked-in `Shaders/prebuilt.metallib`, and if any `.metal` file is newer than the metallib in use, every render prints a loud warning with the fix (`xcodebuild -downloadComponent MetalToolchain`) - no silently-stale shaders.

## Look-dev components

Reusable building blocks extracted from real scenes:

- **`Dither.render(view, size:, cell:, palette:)`** - whole-frame ordered (Bayer 8×8) dither to any palette, CPU-side, no Metal compiler needed. Author in grayscale, get a 1-bit print (`Dither.noir`) or a 4-tone ramp (`Dither.gameBoy`). See `SpiderNoir`.
- **`Stylize`** - sixteen whole-frame renderers driven by a `PixelGrid` snapshot of any view: `.pixel`, `.dither`, `.gameBoy`, `.ascii`, `.halftone`, `.cmyk`, `.mosaic`, `.led`, `.engraving`, `.crosshatch`, `.pointillism`, `.bricks`, `.crossStitch`, `.lowPoly`, `.blueprint`, `.thermal`. CPU + Canvas, deterministic, no Metal compiler. See `StyleLab` - one shot through all sixteen, then all sixteen live in a 4×4 wall:
  ```swift
  let grid = PixelGrid.sample(myScene, size: size, cols: 320)!     // once per frame
  Stylize.view(.ascii, grid: grid, size: size)                     // full-frame
  Stylize.view(.halftone, grid: grid, size: tile, density: 0.5)    // quarter-area tile
  ```
- **`PixelCanvas`** - draw on a logical low-res grid inside `Canvas`: snapped rects, sprites from strings, a 5×7 bitmap font (`PixelFont`), halftone dot screens, halftone type. See `PixelSonnet`.

## Twelve aesthetics, one engine

Swiss, neo-brutalist, Bauhaus, synthwave, glassmorphism, terminal, art deco,
vaporwave, blueprint, stop-motion zine, fluid aurora, kinetic type - each one
compact Swift scenes, chained by a live card-zoom transition, closing on all
twelve running at once:

https://github.com/skyblanket/swift-render/raw/main/docs/assets/style-reel.mp4

```bash
swift run swift-render render StyleReel --audio out/reel.wav
```

## More demos

| | |
|---|---|
| `Release090` - the 0.9 release reel: --jobs, seams, smoke, voice check, Vision, narrated | `swift run swift-render render Release090 --jobs auto` |
| `NeverHeard` - a 93 s narrated short: local TTS voiceover, karaoke captions, dither dissolves | `swift run swift-render render NeverHeard` |
| `StyleLab` - one scene re-rendered 16 ways: pixel, dither, ASCII, halftone, CMYK, mosaic, LED… | `swift run swift-render render StyleLab` |
| `SpiderNoir` - a 1-bit charcoal-and-cream noir short | `swift run swift-render render SpiderNoir` |
| `PixelSonnet` - an 8-bit pixel-art short with a chiptune score | `swift run swift-render render PixelSonnet` |
| `FutureOfTheFirm` - a narrated, animated essay explainer ([docs](future-of-the-firm.md)) | `bash tools/make_firm_audio.sh` |
| `LaunchFilm2` - the launch film: every feature, one file | `swift run swift-render render LaunchFilm2 --audio out/launch.wav` |
| `StyleReel` - 12 aesthetics with card-zoom transitions | `swift run swift-render render StyleReel --audio out/reel.wav` |
| `Kinetic` - 12s kinetic-typography reel: word slams, marquee, galaxy iris, odometer ring | `swift run swift-render render Kinetic` |
| `JustRenderIt` - the hero ad, beat-synced soundtrack included | `swift run swift-render render JustRenderIt --audio audio/jri.m4a` |
| `AudioBars` - audio-reactive + props reference scene | `swift run swift-render render AudioBars --audio audio/jri.m4a` |
| `TimelineDemo` - Timeline/transition/springs reference | `swift run swift-render render TimelineDemo` |
| `ShaderGallery`, `ShaderShowcase`, `TextReveal`, `CardStack`, `ParticleField`, … | `swift run swift-render list` |

https://github.com/skyblanket/swift-render/raw/main/docs/assets/kinetic.mp4

## Vision - live action in, pose and cut-out out

`VisionTrack.load("clip.mov")` runs Apple Vision over a clip **once** - body pose (19 joints),
both hands (21 joints each) and a person segmentation mask per frame - caches it on disk, and
reads it back as a pure function of time, like `AudioTrack`:

```swift
let track = VisionTrack.load(props.clip)          // analyzed once, cached
PoseOverlay(track.frame(at: t))                   // skeleton + hands
track.joint("rightWrist", at: t)                  // interpolated, confidence-filtered
track.mask(at: t)                                 // CGImage, white = person
```

`Rotoscope` cuts the person out, re-renders them through any `Stylize` look, and traces the
skeleton with wrist trails - point it at a clip of yourself:

```bash
echo '{"clip": "me.mov", "style": "ascii"}' > roto.json
swift run swift-render render Rotoscope --props roto.json --jobs auto --out out/roto.mp4
```

The browser-based tools would need JavaScript models in headless Chrome for this; here it's
the Mac's own on-device Vision framework.

## Media - video, images, voiceover, captions

```swift
VideoClip("clips/demo.mp4", at: l)              // frame-accurate (zero-tolerance decode), loop/rate/offset
ImageClip("art/cover.png")                      // any image file on disk
CaptionView(captions, at: t)                    // burned-in captions, karaoke word highlight

static let captions = CaptionTrack(soundtrack(duration: defaultDuration)!)   // from the speak(...) lines

public static func soundtrack(duration: Double) -> Score? {
    Score(duration: duration) {
        sample("clips/demo.mp4", at: 0.3)       // the clip's own audio
        speak("Every meeting, on the record.", at: 1.2)
        sample("openear-foley/click_1.wav", at: 2.4, amp: 0.4)
    }
}
```

Paths resolve against the working directory, `assets/`, and the package root.
`swift-render captions <Scene> --out film.srt` (or `.vtt`) exports the same
captions as a sidecar. See `MediaDemo`.

## How it works

1. Your scene is `(t, duration) → some View` - pure, deterministic, `@MainActor`.
2. `Recorder` walks frames `0..<duration*fps`, renders each via `ImageRenderer`, pipes BGRA pixel buffers into `AVAssetWriter` (H.264, no B-frames), then `MP4Assembler` muxes the audio - the video stream is copied, never re-encoded. `--jobs` splits the frames across processes and the same assembler stitches them.
3. A global `PostFX` pass (film grain + vignette, seeded and deterministic) adds grain and vignette to the output. Opt out with `--no-postfx` or own it per-scene with `ownsPostFX`.
4. Rendering runs locally through native Apple frameworks. External media and optional speech engines have their own inputs and setup.

`swift test` includes a render-twice determinism check. Reproducibility across different environments, assets, and toolchains needs separate validation.
