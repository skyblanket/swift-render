# AI Quickstart

For agents and LLMs working with swift-render. Designed to fit in a small context window.

## Mental model

A **Scene** is a pure SwiftUI function of time. Given `t: Double` (seconds since the scene started) and `duration: Double` (the scene's total length), it returns a `View`. The Recorder calls this function once per frame and encodes the result to MP4.

```swift
public protocol RenderScene {
    associatedtype Body: View
    static var defaultDuration: Double { get }
    @MainActor static func body(at t: Double, duration: Double) -> Body
}
```

Three rules:

1. **No `@State`, no `Timer`, no `withAnimation(.repeatForever)`.** Animation comes from `t`, period.
2. **Use `Ease.clip(t, start, end)` for timing windows.** It returns a 0..1 progress.
3. **Wrap easing.** `Ease.easeOut(Ease.clip(t, 0.5, 1.0))` is the standard pattern.

## Minimal scene template

```swift
import SwiftUI

public struct ExampleScene: RenderScene {
    public static let defaultDuration: Double = 3.0

    public static func body(at t: Double, duration: Double) -> some View {
        // entry: 0.0–0.6s fade-in
        let entry = Ease.easeOut(Ease.clip(t, 0.0, 0.6))
        // exit: last 0.4s fade-out
        let exit = Ease.easeIn(Ease.clip(t, duration - 0.4, duration))
        let visibility = entry * (1.0 - exit)

        return ZStack {
            Color.black.ignoresSafeArea()
            Text("hello")
                .font(.system(size: 96, weight: .semibold))
                .foregroundStyle(.white)
                .opacity(visibility)
                .scaleEffect(0.94 + 0.06 * CGFloat(visibility))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

## Easing reference

```swift
Ease.clip(_ t: Double, _ start: Double, _ end: Double) -> Double  // 0..1 progress in window
Ease.easeOut(_ x: Double) -> Double         // cubic ease-out
Ease.easeIn(_ x: Double) -> Double          // cubic ease-in
Ease.easeInOut(_ x: Double) -> Double       // cubic ease-in-out
```

## Multi-phase timing pattern

For scenes with multiple beats, declare timing windows up top:

```swift
let intro = Ease.easeOut(Ease.clip(t, 0.0, 0.8))
let pulse = Ease.easeInOut(Ease.clip(t, 0.8, 2.0))
let outro = Ease.easeIn(Ease.clip(t, 2.0, 3.0))
```

## Letter-by-letter / staggered reveal

```swift
HStack(spacing: 2) {
    ForEach(Array("HELLO".enumerated()), id: \.offset) { idx, ch in
        let lStart = 0.2 + Double(idx) * 0.05      // 50ms stagger
        let p = Ease.easeOut(Ease.clip(t, lStart, lStart + 0.45))
        Text(String(ch))
            .opacity(p)
            .offset(y: CGFloat(1 - p) * 14)        // drops in 14pt
    }
}
```

## Using shaders from the Cookbook

```swift
Rectangle()
    .fill(.black)
    .colorEffect(
        ShaderLibrary.swiftRender.plasmaField(
            .float2(1920, 1080),
            .float(Float(t)),
            .float(1.4)
        )
    )
```

Available shaders (22; the last four are vinyl/membership-specific): `rimGlow`, `foilHolographic`, `plasmaField`, `chromaticAberration`, `audioBars`, `caustics`, `liquidMetal`, `kaleidoscope`, `truchet`, `galaxy`, `neonGrid`, `smokeFlow`, `warpTunnel`, `metaballs`, `inkFlow`, `interference`, `voronoiInk`, `monoTunnel`, … Exact args: `grep -A8 'half4 name(' Sources/SwiftRender/Shaders/*.metal`.

## Writing a new shader

Append to `Cookbook.metal`:

```metal
[[ stitchable ]]
half4 yourShader(
    float2 position,        // pixel position
    half4 currentColor,     // view's current pixel color
    float2 size,            // view's pixel size
    float someParam         // your custom args
) {
    float2 uv = position / size;
    // your math here
    return half4(half3(0.5, 0.2, 0.8), 1.0h);
}
```

`swift build` recompiles it (needs the Metal compiler: `xcodebuild -downloadComponent MetalToolchain`). After a successful compile, refresh the fallback: `cp .build/release/SwiftRender_SwiftRender.bundle/default.metallib Sources/SwiftRender/Shaders/prebuilt.metallib`.

## Common pitfalls

- **Don't use `@State` in the View** — it won't persist across the per-frame fresh view construction.
- **Don't use `Date()`** — frame deterministic means `t` is the only time source.
- **Don't use `TimelineView`** — its time source isn't synchronized with the Recorder. Just use `t`.
- **`withAnimation { ... }` does nothing useful** — animations interpolate state across renders, but each frame is a fresh render.
- **Text rendering** — use system font with explicit size. SF Pro is default.
- **Background** — always `.frame(maxWidth: .infinity, maxHeight: .infinity)` and a background Color for full-frame scenes.

## CLI reference

```bash
swift run swift-render render <Scene>          # render with defaults
  --duration <s>          # override default duration
  --fps <n>               # default 60
  --aspect 16:9|9:16|1:1  # default 16:9
  --out <path>            # default out/render.mp4
  --audio <path>          # mux audio into output

swift run swift-render list                    # show registered scenes
swift run swift-render new <Scene>             # scaffold an auto-registered scene
swift run swift-render check <Scene>           # contact sheet + audio/sample/voiceover report (review step)
swift run swift-render preview <Scene>         # live window for humans: scrub, play, ←/→ frame-step, audio
swift run swift-render captions <Scene> --out out/x.srt   # voiceover captions sidecar (.srt / .vtt)
```

## The loop an agent should follow when asked to "make a video"

```bash
swift run swift-render new MyFilm            # scaffold (auto-registered — never edit main.swift)
# … write the scene …
swift run swift-render check MyFilm          # READ out/check-MyFilm.png and the printed report
swift run swift-render frame MyFilm --at 2.1,5.4   # zoom in on shots the sheet flagged
swift run swift-render render MyFilm --out out/myfilm.mp4
```

1. **Never skip `check`.** Scenes written blind look generic; the contact sheet is where they get good. Iterate on it 2–3 times before the full render.
2. **You can't hear the mix — read the report.** `check` prints peak/RMS, a loudness lane, silences, clipping and an event histogram; a "mostly percussion loops" warning means add harmony (`chordPad`, `arpeggio`, `melody`).
3. Deliver the one `.swift` file and the render command. Recorder, PostFX, fonts, encoding, registration are all handled.

## Timeline (sequencing without segment math)

```swift
Timeline(t) {
    Clip(2.0) { local in TitleCard(t: local) }                       // local time: 0..<2
    Clip(3.0) { local in Body(t: local) }.transition(.slide(0.45))   // overlaps previous
    Clip(2.5) { local in Outro(t: local) }.transition(.fade(0.5))
    Clip(at: 0, for: 7.0) { local in HUD(t: local) }                 // pinned overlay
}
```

Transitions: `.cut` `.fade(d)` `.slide(d, from: .trailing)` `.flash(d)` `.overlap(d)`.
`stagger(t, i, step: 0.06, ramp: 0.4)` gives cascading per-element progress.

## Springs and extra easings

```swift
Ease.spring(t, from: 0, to: 1, response: 0.45, dampingFraction: 0.55)  // analytic, scrub-safe
Ease.easeOutBack(x)   Ease.elastic(x)   Ease.bounce(x)   Ease.expo(x)
Ease.cubicBezier(0.42, 0, 0.58, 1)(x)
```

## Audio-reactive scenes

Conform to `AudioReactiveScene` (or `PropsAudioScene`); the extra `audio` parameter
is pre-analyzed before rendering, so the scene stays a pure function:

```swift
static func body(at t: Double, duration: Double, audio: AudioTrack) -> some View {
    let bass = audio.band(.bass, at: t)   // 0…1; also .mid, .high, audio.level(at:)
    ...
}
// swift run swift-render render MyScene --audio beat.wav --out out/x.mp4
```

## Props (data-driven scenes)

Conform to `PropsScene` with a `Codable` `Props` + `defaultProps`:

```bash
swift run swift-render props MyScene > p.json   # print template
swift run swift-render render MyScene --props p.json
```
Keep payloads complete — JSON decoding does not apply Swift default values.

## Adapting to render size

Views inside scenes can read the render target from the environment —
one scene, any aspect:

```swift
struct Hero: View {
    @Environment(\.renderContext) var ctx   // size, fps, duration
    var body: some View {
        Text("hi").font(.system(size: ctx.isVertical ? 90 : 140))
    }
}
```

## Soundtracks

Declare audio inside the scene — reuse the same time constants as the Timeline:

```swift
public static func soundtrack(duration: Double) -> Score? {
    Score(duration: duration) {
        fourOnFloor(from: 0, to: chapters.last!)   // kick groove + claps
        crashes(at: chapters)                       // hits on every cut
        boom(at: finale)
    }
}
```
Events: kick/clap/hat/crash/boom/bass/drone/laser (at:).
Transition marks: tick/rim/thump (at:), blip(note, at:), swell(note, at:, duration:), swell(chord, into: t, duration:).
**No swish transitions** — do not use `whoosh` or `riser` in new scenes (they are noise sweeps; `check` flags them).
Mark a cut with the music itself, a `thump`/`rim`/`tick`, or build into it with a chord `swell`.
Melodic: pluck/bell/pad/chip/triBass(note, at:, amp:, duration:, pan:).
Patterns: fourOnFloor, hatSixteenths, bassline(notes:from:to:), every(interval:...).
Render normally — the score synthesizes and muxes automatically.

Music theory — write harmony, not just drums (repetitive drum loops are the #1 "sounds odd" complaint):

```swift
chordPad(.minor7(.a3), at: 0, duration: bar * 2)                // sustained, stereo-spread
strum(.major7(.f3), at: bar * 2)                                 // piano/guitar stab
arpeggio(.minor9(.a4), from: bar, to: bar * 3, step: beat / 4, pattern: .upDown)
melody([(0, .e5), (1, .g5), (1.5, .a5)], start: bar * 4, bpm: 110, instrument: .bell)
Scale.minorPentatonic.degree(i, root: .a4)                       // pick notes procedurally
Note.midi(64)  Note.a3  .transposed(12)
```
Change the chord every bar or two and vary phrases per section — a looped bar reads as a loop.

## Fast iteration

```bash
swift run swift-render frame MyScene --at 1.25 --out out/check.png   # 1 frame, ~1s
swift run swift-render render MyScene --range 2.0:4.5                # partial render
swift run swift-render render MyScene --no-postfx                    # raw frames, no grain/vignette
```

If a scene applies its own `PostFX`, declare `static var ownsPostFX: Bool { true }`
or the recorder's global pass doubles it. Pixel-art and dithered looks should own it
too (grain over a dither reads as noise).

Editing a `.metal` file recompiles automatically on `swift build` — **if** the Metal
compiler is installed. Without it the build uses `Shaders/prebuilt.metallib` and
renders print a loud stale-shader warning; for a new look that must work everywhere,
prefer SwiftUI/Canvas + the CPU `Dither` component over a new shader.

## Look-dev components

```swift
// 1-bit / N-tone print: author in grayscale, dither the whole frame
Dither.render(frameView, size: CGSize(width: 1920, height: 1080), cell: 3,
              palette: Dither.noir, contrast: 1.3, bias: 0.07)

// pixel art on a logical grid (240×135 → ×8 = 1080p)
Canvas { ctx, size in
    var px = PixelCanvas(ctx: ctx, s: size.width / 240)
    px.fillAll(.black)
    px.text("PRESS START", 87, 120, scale: 1, .white)
    px.htText("TITLE", 60, 20, scale: 2, .yellow, shadow: .purple, t: t)   // halftone type
    px.halftone(0, 0, 240, 135, cell: 5) { x, y in y / 135 } color: { _, _ in .purple }
}
```

### Stylize — re-render any view 16 ways

```swift
let shot = Canvas { ctx, size in drawMyScene(ctx, size, t) }       // any View works
let grid = PixelGrid.sample(shot, size: full, cols: 320)!          // one snapshot per frame
Stylize.view(.cmyk, grid: grid, size: full)                        // density: 0.5 for small tiles
// .pixel .dither .gameBoy .ascii .halftone .cmyk .mosaic .led
// .engraving .crosshatch .pointillism .bricks .crossStitch .lowPoly .blueprint .thermal
grid.lum(x, y)  grid.rgb(x, y)  grid.resized(cols:fitting:)  grid.mapped { r, g, b, x, y in … }
```
Writing your own look: read the grid, batch shapes into ONE `Path`, fill once (6,000 dots in a single
fill is far faster than 6,000 fills). Ink-on-paper looks need a tone lift (`pow(lum, 0.5)`) on dark scenes
or they read as negatives. `StyleLab.swift` is the worked example.

## Samples, voiceover, captions

```swift
public static func soundtrack(duration: Double) -> Score? {
    Score(duration: duration) {
        chordPad(.minor7(.a3), at: 0, duration: duration)
        sample("openear-foley/click_1.wav", at: 1.2, amp: 0.4, pan: 0.2)   // foley one-shot
        sample("clips/demo.mp4", at: 3.0, amp: 0.6)                       // a clip's own audio
        speak("Every meeting, on the record.", at: 0.8)                   // local TTS, cached
        crackle(from: 0, to: 4)                                            // vinyl bed
    }
}
static let captions = CaptionTrack(soundtrack(duration: defaultDuration)!)
// in body:  CaptionView(captions, at: t).frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 90)
```

- Paths resolve against cwd, `assets/`, the package root (see `AssetPaths`). `check` lists any missing file.
- `amp: 1` plays a sample at its own level, before the master normalizes; foley usually wants 0.1–0.5.
- Repeated one-shots: vary `rate:` 0.95–1.05 (and pick among several files) so typing/ticks don't machine-gun.
- `speak` defaults to macOS `say`; `engine: .say(voice: "Daniel", wpm: 185)` or `.kokoro(voice: "af_heart")` for better voices. First render synthesizes (~1–3 s/line), then it's cached in `~/Library/Caches/swift-render/tts`.
- Leave ~0.3 s between `speak` lines — check the `voiceover:` line in the report for total speech time.

## Video and image clips

```swift
VideoClip("clips/demo.mp4", at: l)                          // l = seconds into the clip
VideoClip("clips/demo.mp4", at: l, rate: 0.5, loop: true, contentMode: .fit)
ImageClip("art/cover.png")
```

Frames are decoded with zero time tolerance (the same frame every render). Add the clip's sound with `sample(path, at: clipStart)`.

## Rendering long pieces

`swift run swift-render render MyFilm --jobs auto --out out/myfilm.mp4` — parallel processes,
stitched without re-encoding, frame-exact. Use it for anything over ~20 s.

## Voiceover levels (you can't hear them — read the number)

`check` prints `voice vs music: voice sits +X dB above the music`. Aim for a median of +12 dB or
more and a 10th percentile above +6 dB. When it warns, it lists the buried spans — lower the
pads/arps/kicks/samples that overlap those seconds, or raise `speak(…, amp:)`.

## Vision (live action)

```swift
let track = VisionTrack.load("clip.mov")              // pose + hands + person mask, cached
PoseOverlay(track.frame(at: t), color: .green)
track.joint("leftWrist", at: t)                       // VisionPoint, normalized 0…1, top-left origin
track.mask(at: t)                                     // CGImage — use .luminanceToAlpha() as a SwiftUI mask
```
Worked example: `Rotoscope.swift` (PropsScene: `{"clip": "...", "style": "ascii"}`).

## Gotchas learned the hard way

- **Thin strokes vanish** when anything renders below 1:1 (dither at 1/3, contact thumbs): use ≥5 px lines for webs, rain, outlines.
- **Fading by `.opacity` on the whole scene** fades to black only because PostFX lays an opaque base; with `--no-postfx` put your own `Color.black` underneath.
- **Text inside a dithered/pixelated layer gets crunchy** — put subtitles in a crisp overlay above `Dither.render`.
- **Timeline transitions overlap**: the timeline ends earlier than the sum of clip lengths. Give the last clip `duration` and let it be trimmed.
- **Scenes live in `Sources/SwiftRenderScenes`**, a separate target: use `ShaderLibrary.swiftRender` / `Bundle.swiftRender`, not `.module`.
- **Contact sheets sample shot midpoints**; if a frame you care about sits exactly on a cut, use `frame --at`.
- **Big SwiftUI expressions time out on CI's older compiler.** Give intermediate values explicit types, pull per-row views into their own functions, and run `scripts/typecheck-budget.sh` before pushing.
