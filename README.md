<div align="center">

# swift-render

**Programmatic motion graphics in Swift. SwiftUI scenes + real Metal shaders → MP4.**

*The native-Apple answer to Remotion — built for the era where AI writes the motion graphics.*

Point it at a Swift repo and get an Apple-style launch film. Tune the film in a native editor, and hand your notes to an agent.

[![CI](https://github.com/skyblanket/swift-render/actions/workflows/ci.yml/badge.svg)](https://github.com/skyblanket/swift-render/actions/workflows/ci.yml)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)
![Swift 5.10](https://img.shields.io/badge/Swift-5.10-F05138?logo=swift&logoColor=white)
![Release](https://img.shields.io/github/v/tag/skyblanket/swift-render?label=release&color=C7FF1A)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

</div>

https://github.com/skyblanket/swift-render/raw/main/docs/assets/launch-film.mp4

> **The 55-second launch film above is one Swift file** ([`LaunchFilm.swift`](Sources/SwiftRenderScenes/LaunchFilm.swift)) — Timeline sequencing, springs, four live Metal shaders, 3D, an audio-reactive segment, and a synthesized soundtrack. Written by an AI, **3,450 frames rendered in 29 seconds** on a MacBook. Click ▶. Sound on.

```bash
git clone https://github.com/skyblanket/swift-render && cd swift-render
swift run swift-render render JustRenderIt --audio audio/jri.m4a --out out/ad.mp4   # ~7s later: a finished ad, sound included
```

---

## A launch film for any Swift codebase

```bash
swift run swift-render launch ~/Code/MyApp --open           # scan → props → film: MyApp/out/myapp-launch.mp4
swift run swift-render launch ~/Code/MyApp --aspect 9:16    # vertical cut, same props: myapp-launch-9x16.mp4
swift run swift-render init ~/Code/MyApp                    # MyApp/Launch/: the same film as Swift you own
```

Run these from your swift-render checkout. From inside the app's repo, use
`swift run --package-path ~/src/swift-render swift-render launch .`, which does the same thing.

`launch` scans the repo offline: `Package.swift`, `*.xcodeproj`, the `AppIcon` and `AccentColor`,
`Info.plist`, README, CHANGELOG, LICENSE and git. It prints each value it found next to the file it
came from, and it lists conflicts and gaps. It never invents numbers. The facts are written to
`.swift-render/launch/<Name>.json`, and then the built-in `AppleLaunch` scene renders them. You
edit the JSON and run the command again. No rebuild is needed, and a `--preview` render of a
34-second film takes seconds.

The film follows the grammar of an Apple keynote. It opens with "Introducing", then shows the icon
hero, the title, a feature triad, the code or terminal, stats, "What's new", platforms and an end
card. The score is synthesized on whole bars at 100 BPM, and the cuts land on downbeats. There is
one dissolve. There is no camera shake, no flash frame, and no whoosh. Every layout restacks for
9:16, and `--aspect 1:1` stacks into a square layout.

`init` scaffolds a `Launch/` package that depends on swift-render. The film becomes
`Sources/LaunchScenes/<App>Launch.swift`, which is built from **LaunchKit** components
(`KeynoteTitle`, `AppIconHero`, `DeviceFrame`, `FeatureTriad`, `CodeReveal`, `TerminalCard`,
`StatCounter`, `ChangelogList`, `EndCard`, `LaunchScore`, …). The package also gets its own
`launch` CLI:

```bash
cd Launch
swift run launch check MyAppLaunch                 # contact sheet + audio report
swift run launch render MyAppLaunch --preview --open
```

Full reference: [docs/launch.md](docs/launch.md).

## swift-render Studio

![swift-render Studio: AppleLaunch with a region comment on the name, the thread in the inspector, and clip, score and audio lanes on the timeline](docs/assets/studio.png)

Studio is a native macOS editor for swift-render projects. It builds your project's own CLI and
runs it as a render host, so what you see is your code. Studio never interprets a scene itself.

```bash
swift run swift-render-studio .                       # this repo
swift run swift-render-studio ~/Code/MyApp/Launch     # any package whose CLI links SwiftRenderTool
scripts/package-studio.sh                             # → out/Studio/swift-render Studio.app (icon rendered by swift-render)
```

- **Hot reload.** Save a scene and new pixels appear in about 2 s. Builds use their own scratch
  path, so they don't fight your terminal's `swift build`. A failed build keeps the last good
  frame on screen and shows clickable diagnostics.
- **Timeline lanes** come from the engine's own introspection. Clips (with `.named()` labels) link
  to their `file:line`. The timeline also shows score events by lane, the loudness envelope and the
  comments.
- **Viewer.** 16:9, 9:16 and 1:1 canvases, title- and action-safe guides, and A/B compare.
- **Inspector.** Live **knobs** (`Knob.double/bool/text/color`), a props JSON editor, and the
  `check` report.
- **Comments.** Timecoded, with an optional time range and region box. They are stored as plain
  JSON files in `.swift-render/reviews/` that you commit.
- **Agent panel.** Runs headless Claude Code on the comments you select, with only the edit tools,
  the swift-render tools and `swift build` pre-approved. It takes a git checkpoint first, so
  **Revert Run** undoes the run; it backs up the current content first and keeps files you edited
  again afterwards.
- **Render queue.** Presets for Master 1080p60, 4K, 9:16, 1:1, App Store previews (which enforce
  15–30 s), preview and GIF. It shows progress, ETA and stop, and can attach the result to a
  comment.
- **`--snapshot out.png`** draws the window offscreen and exits, for CI and for agents that need to
  see the UI. The screenshot above was made with `--snapshot`.

Studio needs macOS 14+ and a Swift 6 toolchain (Xcode 26) because it compiles your project. Keys,
presets, packaging and notarization are covered in [docs/studio.md](docs/studio.md).

## The review loop

You scrub to the beat that's off, draw a box and type a note. Claude Code then picks the note up.
It finds the clip that draws that moment, edits the Swift and rebuilds. It renders the frame
and *looks at it*. Then it replies with a `file:line` summary and an after-frame, and resolves the
note. You compare before and after in Studio, then accept the change or reopen the note.

```bash
swift run swift-render review add AppleLaunch --at 6.2 --end 7.4 --region 0.36,0.57,0.28,0.17 "name lands a beat late"
swift run swift-render review list
claude --agent swift-render-director "work through the open swift-render comments"
```

- **Comments are files.** `.swift-render/reviews/<Scene>.json` is written under `flock`, so you can
  commit it. `swift-render review list|show|add|reply|status|frame|delete|scenes` drives it
  from the terminal.
- **`swift-render-mcp`** is a stdio MCP server with 13 tools (`list_comments`, `get_comment`,
  `claim_comment`, `render_frames`, `resolve_comment`, `build`, `set_knobs`, …). Frames come back
  inline, so the agent sees what it changed. In this repo, `.mcp.json` registers it.
- **`swift-render-director`** (`.claude/agents/`) is a film-director subagent. It handles one
  comment at a time and keeps `body(at:)` pure. It never uses whoosh, riser or swish. When a note
  is ambiguous, it asks instead of guessing.
- **Other repos** get the agent, the skill and the MCP server from the Claude Code plugin:

  ```
  /plugin marketplace add skyblanket/swift-render
  /plugin install swift-render@swift-render
  ```

  From a shell, the same commands are `claude plugin marketplace add skyblanket/swift-render` and
  `claude plugin install swift-render@swift-render`. The plugin runs `swift-render-mcp` from
  `$SWIFT_RENDER_MCP`, your `PATH` or `swift-render Studio.app`. It builds the server from the
  project (or `./Launch` after `swift-render init`) only in a project you trust: add its path to
  `~/.config/swift-render/trusted-projects`, or set `SWIFT_RENDER_MCP_BUILD=1`.

The CLI, the MCP server, the agent definition and the plugin manifests are covered by tests and
smoke scripts (`scripts/mcp-smoke.py`). A real model turn from end to end has not been observed
on a logged-in machine yet. [docs/review-loop.md](docs/review-loop.md) says exactly what was
verified.

## Why not just use Remotion?

Remotion is great — and it's React rendered by **headless Chromium**, frame by frame, screenshot by screenshot. swift-render is a different bet: render natively on the GPU-accelerated Apple stack, and make every frame a **pure function of time**.

| | **swift-render** | **Remotion** |
|---|---|---|
| Render engine | Native SwiftUI `ImageRenderer` | Headless Chromium screenshots |
| 1080p60 render speed | **~100–140 fps** (M-series) | typically ~15–30 fps |
| Animation model | `t: Double` → View. That's the whole API | `useCurrentFrame()` + hooks, refs, effect deps |
| Determinism | **Proven** — byte-identical re-renders, tested in CI | best-effort (browser, font, thread timing) |
| GPU shaders | **Real Metal** (`.colorEffect`, 22 shaders included) | WebGL/canvas workarounds |
| Typography | Native SF / CoreText, SF Symbols, full blend modes | Web fonts in a browser |
| Audio-reactive | Built-in offline FFT → `audio.band(.bass, at: t)` | `useAudioData` + visualization utils |
| Data-driven renders | `--props file.json` (Codable) | `inputProps` ✓ |
| Sequencing | `Timeline { Clip }` result builder | `<Sequence>` / `<Series>` ✓ |
| License | **MIT — free for everyone** | source-available; free ≤3-person companies, then $25/dev/mo ($100/mo min) |
| Install weight | Swift package, **zero dependencies** | node_modules + a Chromium download |
| Toolchain | `swift run`, done | npm, bundler, browser binaries |
| Runs on | macOS 14+ | anywhere Node runs ✓ |
| Editor | **swift-render Studio**: native macOS app. Hot reload of your Swift, timeline lanes probed from your `Timeline`/`Score`, live knobs. *Preview in 0.10* | Remotion Studio in the browser ✓ (mature) |
| Review → fix loop | Timecoded, region-boxed comments in git → the `swift-render-director` agent (Claude Code + MCP) edits, re-renders, looks and resolves. *Preview: plumbing tested, live model turn not yet verified* | not built in |
| Launch film from a repo | `swift-render launch .` scans the codebase → Apple-style film | start from a template |
| Web player / embeds | ❌ MP4/GIF out only | ✓ `<Player>` — genuinely good |
| Render farm | your Mac (it's fast) | Lambda ✓ |

**Use Remotion** if you need browser embeds, a web player, a mature editor, or Lambda-scale farms.
**Use swift-render** if you want native quality, 5–10× faster local renders, real shaders, a launch film straight from your Swift repo, and an API a language model writes correctly on the first try.

## The whole API fits in your head

A scene is a pure function: time in, view out. No state, no timers, no animation races — and nothing for an LLM to hallucinate.

```swift
import SwiftUI
import SwiftRender

public struct Hello: RenderScene {
    public static let defaultDuration: Double = 3.0

    @MainActor public static func body(at t: Double, duration: Double) -> some View {
        let p = Ease.spring(t, from: 0, to: 1, response: 0.5, dampingFraction: 0.6)
        return Text("hello.")
            .font(.system(size: 120, weight: .black))
            .foregroundStyle(.white)
            .scaleEffect(0.8 + 0.2 * p)
            .opacity(Ease.clip(t, 0, 0.4))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
    }
}
```

Save it anywhere in `Sources/SwiftRenderScenes/` — scenes are **auto-registered** at build time (no dictionary to edit). Or let the CLI scaffold one with a timeline and a score already wired:

```bash
swift run swift-render new Hello                       # scaffold Sources/SwiftRenderScenes/Hello.swift
swift run swift-render check Hello                     # contact sheet + blank-frame scan + audio report
swift run swift-render render Hello --preview --open   # half-res 30fps, opens when done
swift run swift-render render Hello --out out/hello.mp4
```

`check` is the review step: it writes `out/check-Hello.png` (a 4×4 contact sheet sampled at shot midpoints) and a text report — duration, ms/frame, any blank frames, peak/RMS, a loudness lane, silences, clipping and an event histogram. It's built so an agent that can *see* images but can't *hear* audio can still review its own work.

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
hits, so audio/video sync is structural, not manual. The synth is pure Swift,
deterministic, and renders a minute of audio in ~0.1s:

- **Drums & FX:** kick, clap, hat, crash, 808 boom, laser — two-bus sidechain pumping
- **Transition marks:** `tick`, `rim`, `thump`, `blip(note)`, `swell(note)` / `swell(chord, into:)` — tonal and noise-free. House rule: no swish transitions (`whoosh`/`riser` still exist for old scenes; `check` flags them)
- **Melodic voices:** `pluck` (kalimba-ish, with echo), `bell` (FM), `pad` (detuned, slow), `chip` (25% pulse), `triBass` (round triangle), `bass`, `drone`
- **Music theory:** note names (`.a3`, `.c5`, `Note.midi(64)`), `Chord.minor7(.a3)` & friends, `Scale.minorPentatonic.degree(i, root:)`
- **Phrases:** `chordPad`, `strum`, `arpeggio(…, pattern: .upDown)`, `melody([(beat, note)], start:, bpm:)`
- **Samples:** `sample("foley/click.wav", at: t, amp:, pan:, rate:)` — any wav/aiff/m4a/mp3 or the audio of an mp4/mov, decoded once and cached; `rate` varispeed keeps repeats from sounding identical
- **Voiceover:** `speak("…", at: t)` — local TTS (`say`, or Kokoro via `engine: .kokoro()`), cached by content hash so renders stay deterministic; the music ducks ~6 dB under it
- **Texture:** `crackle(from:to:)` — vinyl surface noise bed

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
to their own synthesized score — declare the beat, and the visuals hear it.

## Real Metal shaders

Drop a `.metal` file in `Sources/SwiftRender/Shaders/` and `swift build` — shaders compile automatically (SwiftPM build plugin). Call them on any view:

```swift
Rectangle().fill(.black).colorEffect(
    ShaderLibrary.swiftRender.galaxy(.float2(1920, 1080), .float(Float(t)))
)
```

Eighteen ship in three packs — `rimGlow`, `foilHolographic`, `plasmaField`, `chromaticAberration`, `audioBars`, `caustics`, `liquidMetal`, `kaleidoscope`, `truchet`, `galaxy`, `neonGrid`, `smokeFlow`, `warpTunnel` — plus the studio pack from the launch film: `metaballs` (raymarched chrome), `inkFlow`, `interference`, `voronoiInk`, `monoTunnel`:

https://github.com/skyblanket/swift-render/raw/main/docs/assets/shader-gallery.mp4

Recent Xcodes ship the Metal compiler as a separate download. Without it the build **doesn't fail**: the plugin falls back to the checked-in `Shaders/prebuilt.metallib`, and if any `.metal` file is newer than the metallib in use, every render prints a loud warning with the fix (`xcodebuild -downloadComponent MetalToolchain`) — no silently-stale shaders.

## Look-dev components

Reusable building blocks extracted from real scenes:

- **`Dither.render(view, size:, cell:, palette:)`** — whole-frame ordered (Bayer 8×8) dither to any palette, CPU-side, no toolchain needed. Author in grayscale, get a 1-bit print (`Dither.noir`) or a 4-tone ramp (`Dither.gameBoy`). See `SpiderNoir`.
- **`Stylize`** — sixteen whole-frame renderers driven by a `PixelGrid` snapshot of any view: `.pixel`, `.dither`, `.gameBoy`, `.ascii`, `.halftone`, `.cmyk`, `.mosaic`, `.led`, `.engraving`, `.crosshatch`, `.pointillism`, `.bricks`, `.crossStitch`, `.lowPoly`, `.blueprint`, `.thermal`. CPU + Canvas, deterministic, no toolchain. See `StyleLab` — one shot through all sixteen, then all sixteen live in a 4×4 wall:
  ```swift
  let grid = PixelGrid.sample(myScene, size: size, cols: 320)!     // once per frame
  Stylize.view(.ascii, grid: grid, size: size)                     // full-frame
  Stylize.view(.halftone, grid: grid, size: tile, density: 0.5)    // quarter-area tile
  ```
- **`PixelCanvas`** — draw on a logical low-res grid inside `Canvas`: snapped rects, sprites from strings, a 5×7 bitmap font (`PixelFont`), halftone dot screens, halftone type. See `PixelSonnet`.

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
| `AppleLaunch` — the launch-film template `launch` fills in; its default props are a sample app | `swift run swift-render render AppleLaunch --preview --open` |
| `KnobLab` — knobs reference: drag its sliders in Studio's Knobs tab | `swift run swift-render-studio . --scene KnobLab --tab knobs` |
| `NeverHeard` — a 93 s narrated short: local TTS voiceover, karaoke captions, dither dissolves | `swift run swift-render render NeverHeard` |
| `StyleLab` — one scene re-rendered 16 ways: pixel, dither, ASCII, halftone, CMYK, mosaic, LED… | `swift run swift-render render StyleLab` |
| `SpiderNoir` — a 1-bit charcoal-and-cream noir short | `swift run swift-render render SpiderNoir` |
| `PixelSonnet` — an 8-bit pixel-art short with a chiptune score | `swift run swift-render render PixelSonnet` |
| `FutureOfTheFirm` — a narrated, animated essay explainer ([docs](docs/future-of-the-firm.md)) | `bash tools/make_firm_audio.sh` |
| `LaunchFilm2` — the launch film: every feature, one file | `swift run swift-render render LaunchFilm2 --audio out/launch.wav` |
| `StyleReel` — 12 aesthetics with card-zoom transitions | `swift run swift-render render StyleReel --audio out/reel.wav` |
| `Kinetic` — 12s kinetic-typography reel: word slams, marquee, galaxy iris, odometer ring | `swift run swift-render render Kinetic` |
| `JustRenderIt` — the hero ad, beat-synced soundtrack included | `swift run swift-render render JustRenderIt --audio audio/jri.m4a` |
| `AudioBars` — audio-reactive + props reference scene | `swift run swift-render render AudioBars --audio audio/jri.m4a` |
| `TimelineDemo` — Timeline/transition/springs reference | `swift run swift-render render TimelineDemo` |
| `ShaderGallery`, `ShaderShowcase`, `TextReveal`, `CardStack`, `ParticleField`, … | `swift run swift-render list` |

https://github.com/skyblanket/swift-render/raw/main/docs/assets/kinetic.mp4

## Vision — live action in, pose and cut-out out

`VisionTrack.load("clip.mov")` runs Apple Vision over a clip **once** — body pose (19 joints),
both hands (21 joints each) and a person segmentation mask per frame — caches it on disk, and
reads it back as a pure function of time, like `AudioTrack`:

```swift
let track = VisionTrack.load(props.clip)          // analyzed once, cached
PoseOverlay(track.frame(at: t))                   // skeleton + hands
track.joint("rightWrist", at: t)                  // interpolated, confidence-filtered
track.mask(at: t)                                 // CGImage, white = person
```

`Rotoscope` cuts the person out, re-renders them through any `Stylize` look, and traces the
skeleton with wrist trails — point it at a clip of yourself:

```bash
echo '{"clip": "me.mov", "style": "ascii"}' > roto.json
swift run swift-render render Rotoscope --props roto.json --jobs auto --out out/roto.mp4
```

The browser-based tools would need JavaScript models in headless Chrome for this; here it's
the Mac's own on-device Vision framework.

## Media — video, images, voiceover, captions

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

## CLI

```text
swift-render new    <Scene> [--kind audio]               scaffold an auto-registered scene
swift-render check  <Scene>                              contact sheet + frame scan + audio/sample/voiceover report
swift-render preview <Scene> [--snapshot png]            live window: scrub, play/pause, frame-step, synced audio
swift-render render <Scene> [--duration s] [--fps n] [--aspect 16:9|9:16|1:1] [--width px --height px] [--scale n]
                            [--audio file] [--props file.json] [--knobs file.json] [--range a:b]
                            [--jobs n|auto] [--preview] [--open] [--no-postfx] [--progress json] [--out path]
swift-render frame  <Scene> --at <t>[,t2,…] [--out path.png]   one or several frames
swift-render contact <Scene> [--cols n] [--rows n]       grid contact sheet
swift-render audio  <Scene> --out score.wav              export the scene's Score
swift-render captions <Scene> --out film.srt|.vtt        export voiceover captions
swift-render props  <Scene>                              print default props JSON
swift-render info   <Scene> [--json]                     clips (labels, file:line), knobs, score lanes, captions
swift-render list   [--json]                             all registered scenes
swift-render smoke                                       one frame of every scene + no-swish check (CI)

swift-render launch [path=.] [--out f.mp4] [--aspect 16:9|9:16|1:1] [--preview] [--open]
                    [--voiceover] [--rescan] [--no-render] [--eject] [--no-manifest] [--props-out f.json]
swift-render init   [path=.] [--local <swift-render checkout>] [--force] [--rescan] [--no-manifest]
                                                         scaffold a Launch/ package (never overwrites without --force)
swift-render review list|show|add|reply|status|frame|delete|scenes …        timecoded review comments
swift-render serve                                       Studio's render host (JSON lines + binary frames on stdio)

swift-render-studio [project] [--scene X] [--at t] [--tab comments|knobs|props|info] [--snapshot out.png]
swift-render-mcp                                         MCP server for the review loop (stdio, 13 tools)
```

A valued option with no value or a malformed value exits 64, and `--out` refuses an empty path, a
path ending in `/`, or an existing directory.

**Knobs** override per-scene constants without touching code. `.swift-render/knobs/<Scene>.json`
applies to every render, and `--knobs file.json` swaps in another set for one run. `--scale 2`
encodes 3840×2160 from a 1080p scene, and `--preview` really encodes at half size.

**`--jobs n|auto`** renders in parallel processes and stitches the chunks without re-encoding
(frame-exact against a single-process render). StyleLab, 41 s of 1080p60: 65 s → 19 s at 5 jobs.

**`check`** also measures the mix you can't hear: *voice vs music* reports how many dB the
voiceover sits above the ducked music while someone is speaking, and the exact time spans where
it's buried.

## How it works

1. Your scene is `(t, duration) → some View` — pure, deterministic, `@MainActor`.
2. `Recorder` walks frames `0..<duration*fps`, renders each via `ImageRenderer`, pipes BGRA pixel buffers into `AVAssetWriter` (H.264, no B-frames), then `MP4Assembler` muxes the audio — the video stream is copied, never re-encoded. `--jobs` splits the frames across processes and the same assembler stitches them.
3. A global `PostFX` pass (film grain + vignette, seeded and deterministic) makes raw SwiftUI feel cinema-grade. Opt out with `--no-postfx` or own it per-scene with `ownsPostFX`.
4. There is no step 4. No browser, no server, no project file required.

Studio and the review loop add no new render path. Studio runs your CLI's `serve` as a child
process over stdio, and its exports are ordinary `render` runs. The MCP server shells out to the
same CLI. Every pixel comes from the code above.

Determinism isn't a vibe — `swift test` includes a render-twice-byte-identical check, and CI runs it on every push.

## Use it as a library

```swift
.package(url: "https://github.com/skyblanket/swift-render", from: "0.10.0")
```

| Product | What it is |
|---|---|
| `SwiftRender` | The engine: scene protocols, `Timeline`, `Score`, `Knob`, `Recorder`, shaders, LaunchKit and `AppleLaunch` |
| `SwiftRenderTool` | The whole `swift-render` CLI as a library: `SwiftRenderCommand.main(scenes:)` |
| `SceneRegistryPlugin` | Build plugin. It registers every `public struct X: …Scene` in your CLI target and its same-package dependencies |
| `SwiftRenderKit` | Foundation-only model: `.swift-render/` layout, review comments, host protocol, `LaunchProps`/`LaunchScanner` |
| `SwiftRenderScenes` | The 40-odd demo films. Depend on it only if you want them |

**Your own `swift-render`, for your own scenes.** This is what `swift-render init` generates, and
Studio and the MCP server work with it the same way they work with this repo:

```swift
// Package.swift
products: [.executable(name: "my-films", targets: ["MyFilmsCLI"])],
// …
.target(name: "MyScenes", dependencies: [.product(name: "SwiftRender", package: "swift-render")]),
.executableTarget(
    name: "MyFilmsCLI",
    dependencies: ["MyScenes", .product(name: "SwiftRenderTool", package: "swift-render")],
    plugins: [.plugin(name: "SceneRegistryPlugin", package: "swift-render")]
),
```

```swift
// Sources/MyFilmsCLI/main.swift
import SwiftRenderTool
await SwiftRenderCommand.main(scenes: generatedSceneRunners)   // written by SceneRegistryPlugin
```

```jsonc
// swift-render.json at the package root: marks the project for Studio, `review` and the MCP server
{"product": "my-films", "scenesDir": "Sources/MyScenes"}
```

Now `swift run my-films render|check|info|review|serve …` works on your scenes, and the
built-in `AppleLaunch` scene comes along too. Name the executable *product* whatever you like.
Don't name the *module* `launch`, because that name shadows a Darwin module.

You can also skip the CLI and drive the engine directly:

```swift
import SwiftRender

let recorder = Recorder(config: .init(fps: 60, size: .init(width: 1920, height: 1080)))
try await recorder.render(to: url, duration: 5) { t in MyView(t: t) }
```

Code outside the engine reaches the bundled shaders and resources through
`ShaderLibrary.swiftRender` and `Bundle.swiftRender`.

## For AI agents

**Any agent, any Swift repo.** `swift-render-mcp` is a stdio MCP server for Claude Code, Claude
Desktop, Codex and Cursor. Point it at any Swift codebase and an agent can make a launch film with
`launch_film`. It sees the result as a contact sheet and edits the copy through props. It can also
scaffold and write its own scenes (`init_project`, `new_scene`), look at frames, check the audio
and render MP4s. The API guide is built in (`docs`, and the resources `swift-render://docs/<topic>`).
Inside a swift-render project it also runs the review loop.
[docs/agents.md](docs/agents.md) covers the build, a config snippet for each client, the modes,
and the plain-CLI equivalents for agents without MCP.

```bash
swift build -c release --product swift-render && swift build -c release --product swift-render-mcp
claude mcp add --scope user swift-render -- "$(swift build -c release --show-bin-path)/swift-render-mcp"
```

`docs/ai-quickstart.md` is a compact, LLM-ready guide to the whole API, including knobs, clip labels, LaunchKit, `launch`/`init` and the `review` CLI. The design goal: an agent that has never seen this repo writes a working, good-looking scene on the first attempt. (This README's hero ad is the proof.)

To have an agent work through review notes, use the `swift-render-director` agent and the `swift-render` MCP server (see [The review loop](#the-review-loop)). Studio's `--snapshot` lets an agent see the editor itself.

Deeper docs: [launch.md](docs/launch.md) · [studio.md](docs/studio.md) · [review-loop.md](docs/review-loop.md).

## Requirements

- macOS 14+ (Apple silicon recommended; that's where the speed numbers come from)
- Engine and CLI: Xcode 16 or later (CI builds on macOS 15; the manifest is tools-version 5.10). The Metal compiler is only needed when **editing** shaders (`xcodebuild -downloadComponent MetalToolchain`); a prebuilt metallib covers everything else
- Studio: Swift 6 / Xcode 26, because it compiles your project. It is not sandboxed. To ship it to other Macs, sign it with Developer ID and notarize it ([docs/studio.md](docs/studio.md#notarizing-for-distribution))
- Review loop: [Claude Code](https://claude.com/claude-code) (`claude`), logged in
- ffmpeg is optional. It's handy for GIF/thumbnail post-processing, and Studio needs it for GIF exports and to keep the sound on In→Out exports
- Voiceover uses macOS `say` (install Premium voices in System Settings › Accessibility › Spoken Content for better quality) or Kokoro (`tools/kokoro_tts.py` + `.venv-kokoro`)

## Roadmap

See [ROADMAP.md](ROADMAP.md). The goal is to make swift-render the default way Swift teams make
launch films, App Store previews and release videos. It rests on four pillars: the engine, Studio,
the review loop and (later) cloud review links. Next up is **0.11, "Launch everywhere"**. It brings
an App Store Preview Kit that enforces Apple's spec, ProRes 4444 and HEVC-with-alpha masters,
more LaunchKit styles, your app's real SwiftUI views inside `DeviceFrame`, and
`swift-render doctor`.

Linux? No — this is proudly the native-Apple lane.

## License

MIT — see [LICENSE](LICENSE).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Scenes must stay pure functions of `t` — that rule is the product.
