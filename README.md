# Swift Render

**A code-first video engine for Swift developers.**

Build motion graphics, data-driven films, and video tools with SwiftUI, Metal, and native Apple frameworks. Write scenes as functions of time, score them in Swift, and render them to MP4 on your Mac.

Swift Render is an engine and CLI. Use it directly to author films, or embed the library in your own app or workflow.

## What you can build

- App launch and product videos, rendered straight from your Swift code.
- Motion graphics with native typography, analytic springs, timelines, and Metal shaders.
- Films driven by JSON props, video clips, images, voiceover, and captions.
- Audio-reactive scenes with a native Swift score, synthesis, samples, and cached local speech.
- Live-action effects using Apple Vision pose, hand tracking, and person masks. The `Rotoscope` demo combines these with stylized cut-outs.
- Local render workflows with parallel jobs, frame/range exports, contact sheets, and audio reports.

[Feature guide](docs/features.md) · [CLI reference](docs/cli.md) · [Launch films](docs/launch.md) · [Studio](docs/studio.md) · [For agents](AGENTS.md) · [AI quickstart](docs/ai-quickstart.md) · [Contributing](CONTRIBUTING.md)

## Quick start

Requires macOS 14+ and the Xcode 15+ toolchain. Apple silicon is recommended. The bundled prebuilt Metal library lets you use existing shaders without installing the separate Metal compiler; editing shaders needs that compiler.

```bash
git clone https://github.com/skyblanket/swift-render.git
cd swift-render
swift run swift-render list
swift run swift-render render KineticType --out out/kinetic-type.mp4
```

`KineticType` declares its own Swift soundtrack, which is synthesized and muxed automatically. An explicit `--audio file` overrides a scene's score.

For a short review render:

```bash
swift run swift-render check KineticType
swift run swift-render render KineticType --preview --open
```

`check` produces a contact sheet and frame/audio report. Inspect the pictures and listen to the actual export: automated checks do not establish visual or musical quality.

## A scene is a function of time

```swift
import SwiftUI
import SwiftRender

public struct Hello: RenderScene {
    public static let defaultDuration: Double = 3.0

    @MainActor
    public static func body(at t: Double, duration: Double) -> some View {
        let p = Ease.spring(t, from: 0, to: 1,
                            response: 0.5, dampingFraction: 0.6)
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

Save it in `Sources/SwiftRenderScenes/Hello.swift`. The build plugin discovers scenes automatically. Or scaffold a scene with timeline and score hooks:

```bash
swift run swift-render new Hello
swift run swift-render check Hello
swift run swift-render render Hello --out out/hello.mp4
```

Keep scenes free of timers and mutable animation state. Frame time drives the output, so preview, frame export, and full render use the same scene logic.

## Sound belongs in the scene

The native `Score` DSL places drums, melodic voices, samples, and speech on the same timeline as the visuals. Export a scene's track on its own:

```bash
swift run swift-render audio KineticType --out out/score.wav
```

Audio-reactive scenes read cached bass, mid, high, and RMS envelopes. Local voiceover can use macOS `say` or an optional Kokoro setup. The `check` command reports clipping, silence, and voice/music balance. See [sound and media](docs/features.md).

## Vision and parallel rendering

```bash
printf '%s\n' '{"clip":"me.mov","style":"ascii"}' > roto.json
swift run swift-render render Rotoscope --props roto.json --jobs auto --out out/roto.mp4
```

`VisionTrack` analyzes body pose, hands, and person segmentation once and caches the result. `--jobs` splits rendering across processes and stitches chunks without re-encoding. `--range a:b` exports a picture-only section on the same frame grid as a full render.

These features are part of the engine, independent of any editor built on top of it. See [Vision examples](docs/features.md) and [render options](docs/cli.md).

## Launch films for Swift codebases

```bash
swift run swift-render launch /path/to/MyApp --preview --open
```

`launch` reads a codebase's `Package.swift` or `.xcodeproj`, app icon, accent color, README, CHANGELOG and git history, then renders the `AppleLaunch` template at 16:9, 9:16 or 1:1. It prints each detected value with its source and writes the content to `.swift-render/launch/<Name>.json`, which you can edit and re-render. `swift-render init /path/to/MyApp` scaffolds a `Launch/` package with the film as editable Swift and its own CLI. See [Launch films](docs/launch.md).

## Studio

```bash
swift run swift-render-studio
```

swift-render Studio is a native macOS editor built on the CLI. It rebuilds and reloads a scene when you save, shows clips, score and waveform on a timeline, edits knobs and props live, and keeps timecoded comments (optionally boxed to a region of the frame) in `.swift-render/reviews/`. Exports run in parallel processes with a release build. `scripts/package-studio.sh` produces a signed `.app`. See [Studio](docs/studio.md).

## Agents and the review loop

`swift-render-mcp` is a stdio MCP server for Claude Code, Claude Desktop, Codex and Cursor. It works in any Swift repo: an agent can make a launch film (`launch_film`), look at frames and contact sheets, edit content (`get_props`, `set_props`), write scenes (`new_scene`, `write_scene`) and render video. Inside a project it also resolves review comments left in Studio. Claude Code gets a `swift-render-director` agent and a plugin. Start at [AGENTS.md](AGENTS.md); setup for each client is in [docs/agents.md](docs/agents.md) and the comment workflow in [docs/review-loop.md](docs/review-loop.md).

## Use the library in your app

Add the package and depend on its `SwiftRender` product:

```swift
.package(url: "https://github.com/skyblanket/swift-render", from: "0.10.0")
```

```swift
import SwiftRender

let recorder = Recorder(config: .init(
    fps: 60, size: .init(width: 1920, height: 1080)
))
try await recorder.render(to: outputURL, duration: 5) { t in
    MyView(t: t)
}
```

Call the recorder from a main-actor context. The `SwiftRenderScenes` product contains the demo collection and is optional for library users. To ship your own `swift-render`-style CLI for your scenes, depend on `SwiftRenderTool` and apply the `SceneRegistryPlugin` to your executable target (`swift-render init` sets this up). Access bundled shaders through `ShaderLibrary.swiftRender` and resources through `Bundle.swiftRender`.

## Repository map

| Path | Purpose |
| --- | --- |
| `Sources/SwiftRender/` | Engine: rendering, timelines, audio, media, Vision, components, shaders |
| `Sources/SwiftRenderScenes/` | Demo scenes, separate from the reusable engine |
| `Sources/SwiftRenderTool/` | The CLI as a library: authoring, preview, checks, export, `serve`, `launch`, `review` |
| `Sources/SwiftRenderCLI/` | This repo's `swift-render` executable (one line plus the scene registry) |
| `Sources/SwiftRenderKit/` | Foundation-only shared model: project layout, review comments, host protocol, builds |
| `Sources/SwiftRenderStudio/` | The native editor (depends only on `SwiftRenderKit`) |
| `Sources/SwiftRenderMCP/` | The MCP server for agents |
| `Plugins/` | Metal compilation and scene registration |
| `Tests/SwiftRenderTests/` | Engine, CLI, host, MCP and review tests, including determinism and audio/media tests |
| `Tests/SwiftRenderStudioTests/` | Studio tests against a fake host (real-host tests are opt-in) |
| `docs/` | Guides, examples, and checked-in demo assets |
| `tools/`, `scripts/` | Supporting authoring and development tools |
| `out/` | Generated renders and review files; ignored by Git |

[Documentation index](docs/README.md) explains where to start. This layout keeps engine code, examples, and tooling separate.

## Examples and community

Start with `KineticType` for motion and scoring, `AudioBars` for audio-reactive props, `StyleLab` for whole-frame looks, `Rotoscope` for Vision, and `Release090` for a narrated feature reel. Use `swift run swift-render list` for the full scene list.

[Launch film](docs/assets/launch-film.mp4) · [Shader gallery](docs/assets/shader-gallery.mp4) · [Style reel](docs/assets/style-reel.mp4)

## Scope and requirements

- macOS 14+; this is a native Apple rendering stack, not a cross-platform browser renderer.
- Xcode 15+; install the separate Metal toolchain when editing shaders.
- Local rendering and preview. No hosted render farm or embeddable web player is included. See [ROADMAP.md](ROADMAP.md).
- Optional Kokoro dependencies are separate from the Swift package. macOS `say` works without that setup.
- Timing is designed to be deterministic and has regression tests. Do not assume byte-identical results across every OS, toolchain, font, or external media change.

For development, run `swift build`, `swift test`, and `swift run swift-render smoke`. See [Contributing](CONTRIBUTING.md).

## License

[MIT](LICENSE). Keep the copyright and license notice with copies or substantial portions of the software. Your own app code, assets, and rendered content retain their own licenses.
