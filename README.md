<div align="center">

# swift-render

**Programmatic motion graphics in Swift. SwiftUI scenes + real Metal shaders → MP4.**

*The native-Apple answer to Remotion — built for the era where AI writes the motion graphics.*

[![CI](https://github.com/skyblanket/swift-render/actions/workflows/ci.yml/badge.svg)](https://github.com/skyblanket/swift-render/actions/workflows/ci.yml)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)
![Swift 5.10](https://img.shields.io/badge/Swift-5.10-F05138?logo=swift&logoColor=white)
![Release](https://img.shields.io/github/v/tag/skyblanket/swift-render?label=release&color=C7FF1A)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

</div>

https://github.com/skyblanket/swift-render/raw/main/docs/assets/launch-film.mp4

> **The 55-second launch film above is one Swift file** ([`LaunchFilm.swift`](Sources/SwiftRender/Scenes/LaunchFilm.swift)) — Timeline sequencing, springs, four live Metal shaders, 3D, an audio-reactive segment, and a synthesized soundtrack. Written by an AI, **3,450 frames rendered in 29 seconds** on a MacBook. Click ▶. Sound on.

```bash
git clone https://github.com/skyblanket/swift-render && cd swift-render
swift run swift-render render JustRenderIt --audio audio/jri.m4a --out out/ad.mp4   # ~7s later: a finished ad, sound included
```

---

## Why not just use Remotion?

Remotion is great — and it's React rendered by **headless Chromium**, frame by frame, screenshot by screenshot. swift-render is a different bet: render natively on the GPU-accelerated Apple stack, and make every frame a **pure function of time**.

| | **swift-render** | **Remotion** |
|---|---|---|
| Render engine | Native SwiftUI `ImageRenderer` | Headless Chromium screenshots |
| 1080p60 render speed | **~100–140 fps** (M-series) | typically ~15–30 fps |
| Animation model | `t: Double` → View. That's the whole API | `useCurrentFrame()` + hooks, refs, effect deps |
| Determinism | **Proven** — byte-identical re-renders, tested in CI | best-effort (browser, font, thread timing) |
| GPU shaders | **Real Metal** (`.colorEffect`, 12 shaders included) | WebGL/canvas workarounds |
| Typography | Native SF / CoreText, SF Symbols, full blend modes | Web fonts in a browser |
| Audio-reactive | Built-in offline FFT → `audio.band(.bass, at: t)` | `useAudioData` + visualization utils |
| Data-driven renders | `--props file.json` (Codable) | `inputProps` ✓ |
| Sequencing | `Timeline { Clip }` result builder | `<Sequence>` / `<Series>` ✓ |
| License | **MIT — free for everyone** | source-available; free ≤3-person companies, then $25/dev/mo ($100/mo min) |
| Install weight | Swift package, **zero dependencies** | node_modules + a Chromium download |
| Toolchain | `swift run`, done | npm, bundler, browser binaries |
| Runs on | macOS 14+ | anywhere Node runs ✓ |
| Web preview/player | ❌ render PNG/MP4 fast instead | ✓ Studio + `<Player>` — genuinely good |
| Render farm | your Mac (it's fast) | Lambda ✓ |

**Use Remotion** if you need browser embeds, a web player, or Lambda-scale farms.
**Use swift-render** if you want native quality, 5–10× faster local renders, real shaders, and an API a language model writes correctly on the first try.

## The whole API fits in your head

A scene is a pure function: time in, view out. No state, no timers, no animation races — and nothing for an LLM to hallucinate.

```swift
import SwiftUI

public struct Hello: RenderScene {
    public static let defaultDuration: Double = 3.0

    @MainActor public static func body(at t: Double, duration: Double) -> some View {
        let p = Ease.spring(t, from: 0, to: 1, response: 0.5, dampingFraction: 0.6)
        Text("hello.")
            .font(.system(size: 120, weight: .black))
            .foregroundStyle(.white)
            .scaleEffect(0.8 + 0.2 * p)
            .opacity(Ease.clip(t, 0, 0.4))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
    }
}
```

Register it in `Sources/SwiftRenderCLI/main.swift`, then:

```bash
swift run swift-render render Hello --out out/hello.mp4
swift run swift-render frame Hello --at 1.2 --out out/check.png   # preview one frame in ~1s
```

### Sequencing — `Timeline`

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

### Springs — closed-form, scrub-safe

`Spring` is solved **analytically** (under/critical/overdamped) — position at any `t` is computed directly, never integrated. Scrub to frame 4081 and get the exact same pixels, every run. Plus `easeOutBack`, `elastic`, `bounce`, `expo`, `cubicBezier(…)`.

### Audio-reactive — `--audio`

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

> The soundtrack itself is generated by `tools/make_jri_audio.py` — kicks, whooshes and an 808 placed at the scene's exact timeline anchors. Audio and video can't drift, by construction.

### Data-driven — `--props`

```bash
swift run swift-render props AudioBars > p.json     # JSON template from the scene's defaults
swift run swift-render render AudioBars --props p.json --audio beat.wav
```

Pipe in JSON per record and render a thousand personalized variants — the AI/data-pipeline workflow Remotion's `inputProps` made popular, native.

## Sound, in Swift

Scenes declare their own soundtrack — same constants drive the cuts and the
hits, so audio/video sync is structural, not manual. The synth (kicks, claps,
hats, crashes, sub bass, risers, 808 booms, drones, whooshes — with two-bus
sidechain pumping) is pure Swift, deterministic, and renders a minute of audio
in ~0.1s:

```swift
public static func soundtrack(duration: Double) -> Score? {
    Score(duration: duration) {
        fourOnFloor(from: 2.4, to: 33.6)          // kicks + backbeat claps
        hatSixteenths(from: 2.4, to: 33.6)
        bassline([.a1, .a1, .c2, .g1], from: 2.4, to: 33.6)
        crashes(at: chapters)                      // the SAME array as the Timeline
        riser(at: 33.6, duration: 2.4)
        boom(at: 36.0)
    }
}
```

```bash
swift run swift-render render KineticType        # score synthesized + muxed, zero flags
swift run swift-render audio KineticType --out out/score.wav   # export the track alone
```

`--audio file` always wins over a scene's score. Audio-reactive scenes react
to their own synthesized score — declare the beat, and the visuals hear it.

## Real Metal shaders

Drop a `.metal` file in `Sources/SwiftRender/Shaders/` and `swift build` — shaders compile automatically (SwiftPM build plugin). Call them on any view:

```swift
Rectangle().fill(.black).colorEffect(
    ShaderLibrary.bundle(.module).galaxy(.float2(1920, 1080), .float(Float(t)))
)
```

Eighteen ship in three packs — `rimGlow`, `foilHolographic`, `plasmaField`, `chromaticAberration`, `audioBars`, `caustics`, `liquidMetal`, `kaleidoscope`, `truchet`, `galaxy`, `neonGrid`, `smokeFlow`, `warpTunnel` — plus the studio pack from the launch film: `metaballs` (raymarched chrome), `inkFlow`, `interference`, `voronoiInk`, `monoTunnel`:

https://github.com/skyblanket/swift-render/raw/main/docs/assets/shader-gallery.mp4

(If a `.metal` file is newer than the compiled metallib, the CLI warns you loudly — no silently-stale shaders.)

## Twelve aesthetics, one engine

Swiss, neo-brutalist, Bauhaus, synthwave, glassmorphism, terminal, art deco,
vaporwave, blueprint, stop-motion zine, fluid aurora, kinetic type — each one
~40 lines of Swift, chained by a live card-zoom transition, closing on all
twelve running at once:

https://github.com/skyblanket/swift-render/raw/main/docs/assets/style-reel.mp4

```bash
swift run swift-render render StyleReel --audio out/reel.wav
```

## More demos

| | |
|---|---|
| `LaunchFilm2` — the launch film: every feature, one file | `swift run swift-render render LaunchFilm2 --audio out/launch.wav` |
| `StyleReel` — 12 aesthetics with card-zoom transitions | `swift run swift-render render StyleReel --audio out/reel.wav` |
| `Kinetic` — 12s kinetic-typography reel: word slams, marquee, galaxy iris, odometer ring | `swift run swift-render render Kinetic` |
| `JustRenderIt` — the hero ad, beat-synced soundtrack included | `swift run swift-render render JustRenderIt --audio audio/jri.m4a` |
| `AudioBars` — audio-reactive + props reference scene | `swift run swift-render render AudioBars --audio audio/jri.m4a` |
| `TimelineDemo` — Timeline/transition/springs reference | `swift run swift-render render TimelineDemo` |
| `ShaderGallery`, `ShaderShowcase`, `TextReveal`, `CardStack`, `ParticleField`, … | `swift run swift-render list` |

https://github.com/skyblanket/swift-render/raw/main/docs/assets/kinetic.mp4

## CLI

```text
swift-render render <Scene> [--duration s] [--fps n] [--aspect 16:9|9:16|1:1]
                            [--audio file] [--props file.json] [--range a:b]
                            [--no-postfx] [--out path]
swift-render frame  <Scene> --at <t> [--out path.png]    fast single-frame preview
swift-render props  <Scene>                              print default props JSON
swift-render list                                        all registered scenes
```

## How it works

1. Your scene is `(t, duration) → some View` — pure, deterministic, `@MainActor`.
2. `Recorder` walks frames `0..<duration*fps`, renders each via `ImageRenderer`, pipes BGRA pixel buffers into `AVAssetWriter` (H.264), muxes audio with `AVMutableComposition`.
3. A global `PostFX` pass (film grain + vignette, seeded and deterministic) makes raw SwiftUI feel cinema-grade. Opt out with `--no-postfx` or own it per-scene with `ownsPostFX`.
4. There is no step 4. No browser, no server, no project file.

Determinism isn't a vibe — `swift test` includes a render-twice-byte-identical check, and CI runs it on every push.

## Use it as a library

```swift
.package(url: "https://github.com/skyblanket/swift-render", from: "0.5.0")
```

```swift
import SwiftRender

let recorder = Recorder(config: .init(fps: 60, size: .init(width: 1920, height: 1080)))
try await recorder.render(to: url, duration: 5) { t in MyView(t: t) }
```

## For AI agents

`docs/ai-quickstart.md` is a compact, LLM-ready guide to the whole API. The design goal: an agent that has never seen this repo writes a working, good-looking scene on the first attempt. (This README's hero ad is the proof.)

## Requirements

- macOS 14+ (Apple silicon recommended; that's where the speed numbers come from)
- Xcode 15+ toolchain (`xcrun metal` needed only when editing shaders)
- ffmpeg optional — handy for GIF/thumbnail post-processing

## Roadmap

- SwiftPM build plugin for automatic metallib compilation
- `contact <Scene>` grid-sheet export · transparent ProRes 4444 · 10-bit masters
- Audio-reactive FFT improvements (configurable bands, onset detection)
- Linux? No — this is proudly the native-Apple lane.

## License

MIT — see [LICENSE](LICENSE).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Scenes must stay pure functions of `t` — that rule is the product.
