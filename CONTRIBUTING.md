# Contributing to swift-render

Swift Render is a reusable video engine, a CLI, and a separate collection of demo scenes. Keep each change in the layer that owns it.

## Layout

```
Sources/
  SwiftRenderKit/      Foundation-only shared model (no SwiftUI): Project + .swift-render/ layout,
                       Review comments + ReviewStore (flock), ReviewImage, render-host wire protocol
                       (HostProtocol), SceneInfo, streaming builds + diagnostics (Build),
                       Launch/ (LaunchProps, LaunchPlan, LaunchScanner)
  SwiftRender/         The engine: scene protocols, Timeline, Spring/Ease, Score + synth, Knob,
                       Introspection (clip/knob/score probes), Recorder + MP4Assembler, PostFX,
                       components (Dither, Stylize, Media, VisionTrack…), LaunchKit/ (+ AppleLaunch),
                       Shaders/ (*.metal + prebuilt.metallib), Resources/
  SwiftRenderTool/     The CLI as a library: SwiftRenderCommand.main(scenes:), render/frame/check/
                       preview/info/smoke/--jobs, serve (Studio host), launch/init, review
  SwiftRenderCLI/      main.swift for this repo's `swift-render` (one line + SceneRegistryPlugin)
  SwiftRenderScenes/   The demo films. Not part of the engine
  SwiftRenderStudio/   swift-render Studio (SwiftUI app; depends only on SwiftRenderKit):
                       App/ Core/ (build, host, playback, review, agent, render queue) Timeline/
                       Viewer/ Inspector/ Render/ Sidebar/ Agent/
  SwiftRenderMCP/      swift-render-mcp: hand-written MCP stdio server (21 tools)
Plugins/
  MetalCompilerPlugin/ compiles Shaders/*.metal (falls back to prebuilt.metallib)
  SceneRegistryPlugin/ generates the scene registry for a CLI target + its same-package deps
Tests/
  SwiftRenderTests/        engine, Kit, host, review loop, launch, determinism
  SwiftRenderStudioTests/  Studio, against FakeHost / fake processes (real-host tests are opt-in)
Support/Studio/        Info.plist + entitlements for the packaged app
.claude/ claude-plugin/ .claude-plugin/   director agent, make + review skills, Claude Code plugin + marketplace
scripts/               host-smoke.py, mcp-smoke.py, package-studio.sh, typecheck-budget.sh, embed-quickstart.py
tools/                 voiceover and audio pipelines for the narrated demo films
docs/                  guides; start at docs/README.md (architecture.md explains how the pieces fit)
```

Dependency rule: Studio and the MCP server link **only** `SwiftRenderKit`. They never import the
engine. Everything that renders goes through the project's own CLI (`serve`, `render`, `frame`,
`info`, `review`). That is why Studio and the review loop work on any package whose CLI links
`SwiftRenderTool`, and not just on this repo.

Keep app-specific assets and demo behavior out of the engine when practical. Avoid bundling private source, credentials, or assets without permission.

## Development loop

```bash
swift build                                              # everything (~20 s clean on an M-series Mac)
swift test                                               # the full suite
swift run swift-render render <YourScene> --preview --open
swift run swift-render smoke                             # what CI runs after the tests
swift run swift-render-studio .                          # Studio against this repo
```

Studio builds the project into `.build/studio`, so it doesn't contend with your terminal's
`swift build`.

## Adding a scene

1. Create `Sources/SwiftRenderScenes/YourScene.swift` implementing `RenderScene`:
   ```swift
   import SwiftUI
   import SwiftRender

   public struct YourScene: RenderScene {
       public static let defaultDuration: Double = 3.0
       @MainActor public static func body(at t: Double, duration: Double) -> some View {
           // pure function of t — see Easing.swift for helpers
       }
   }
   ```
   (or `swift run swift-render new YourScene` to scaffold one with a Timeline + Score).
2. That's it for registration - `SceneRegistryPlugin` finds every `public struct X` that
   conforms to a scene protocol and registers it as `"X"` at build time.
3. Give clips `.named("…")` labels and expose tunables as `Knob`s, so Studio, review comments and
   agents can point at them.
4. `swift run swift-render check YourScene`, review the contact sheet + report, then render.

## Adding a LaunchKit component

Put it in `Sources/SwiftRender/LaunchKit/`. Components are `View`s that are pure in a local time
`at t:`. They read `\.launchTheme` and `\.renderContext` and restack for 9:16. If a component makes
a sound, expose its timing as a static helper (like `FeatureTriad.landTimes`), so a score can hit
the same frames. Keep the house grammar: no camera shake, no flash frames, no whoosh/riser.
Then cover it in `Tests/SwiftRenderTests/LaunchTests.swift` and `docs/launch.md`.

## Adding a shader

1. Add a `[[ stitchable ]]` function to a `.metal` file in `Sources/SwiftRender/Shaders/`.
2. `swift build` - the MetalCompilerPlugin compiles all shaders into the
   metallib automatically. This needs the Metal compiler
   (`xcodebuild -downloadComponent MetalToolchain`); without it the build falls back
   to `Shaders/prebuilt.metallib` and renders warn that your edit isn't live.
3. After a successful compile, refresh the fallback so toolchain-less machines get it:
   `cp .build/release/SwiftRender_SwiftRender.bundle/default.metallib Sources/SwiftRender/Shaders/prebuilt.metallib`
4. Use it in a scene via `ShaderLibrary.swiftRender.yourShader(...)` (scenes live in another target, so `.module` would be the wrong bundle).

## Contracts to keep in sync

- **Host protocol** (`SwiftRenderKit/HostProtocol.swift`): `serve` and Studio must agree.
  `WireTests` and `HostTests` cover both ends, and `python3 scripts/host-smoke.py` drives a real
  host over pipes.
- **MCP tool names** are a contract with Studio and the director agent. After any change, run
  `python3 scripts/mcp-smoke.py --full`.
- **Director agent**: `.claude/agents/swift-render-director.md` and
  `claude-plugin/agents/swift-render-director.md` may differ only in their tool prefixes.
  `ReviewLoopTests` checks this. Run `claude plugin validate claude-plugin` and
  `claude plugin validate .` after you edit a manifest.
- **Version**: `swiftRenderVersion` in `SwiftRenderTool/Tool.swift`, `CHANGELOG.md`,
  `.claude-plugin/marketplace.json`, `claude-plugin/.claude-plugin/plugin.json`,
  `Support/Studio/Info.plist` (`CFBundleShortVersionString`), and the `from:` that
  `swift-render init` writes.
- **The API guide** `docs/ai-quickstart.md` is compiled into `swift-render-mcp`. After editing it,
  run `python3 scripts/embed-quickstart.py` (`MCPCreateTests` fails until you do).

## Tests

```bash
swift build
swift test
swift run swift-render smoke
```

`swift test` runs the whole suite. It includes a render-twice-byte-identical check that CI runs on
every push. Studio tests run against `FakeHost` and fake processes by default. The slow ones and
the ones that cost money are opt-in:

| Env var | What it runs |
|---|---|
| `SR_STUDIO_E2E=1` | hot-reload E2E: real FSEvents, `swift build --scratch-path`, host swap |
| `SR_STUDIO_REAL_E2E=1` | builds this repo and drives the real `serve` host (knobs, review, hot reload) |
| `SR_STUDIO_REAL_CLAUDE=1` | one real (paid) `claude -p` turn; needs `claude` logged in |

UI checks use snapshots: `swift run swift-render-studio . --scene TimelineDemo --at 3 --snapshot out/studio.png`
(see the snapshot options in [docs/studio.md](docs/studio.md#command-line-and-snapshots)).
`scripts/package-studio.sh` builds, signs and launches the packaged app as an end-to-end check.

Add a regression test for engine changes. For visual changes, inspect representative frames and the
encoded movie. For sound changes, listen to the export as well as reading the audio report. A passing
build is not a review of the output.

## Style

- Keep scenes pure functions of `t`. No `@State`, no `Timer`, no `withAnimation(.repeatForever)`.
- Use `Ease.clip(t, start, end)` and the easing helpers for timing.
- Document scene timing in the doc comment (`0.0–1.2s : …`).
- Frame the body method `@MainActor`.
- No `whoosh`/`riser`/swish sounds in scores (`smoke` and `check` flag them). Mark cuts with
  `tick`/`rim`/`thump`/`blip`/`swell` or with the music itself.
- Public APIs need doc comments.
- Big SwiftUI expressions time out on CI's older compiler, so run `scripts/typecheck-budget.sh`
  before you push.

## Reporting bugs

Open an issue with:
- Scene name
- Command line you ran
- Expected vs actual (frame extracts via `ffmpeg -ss N -update 1 -frames:v 1` help a lot)
- macOS + Swift version
- For Studio: a `--snapshot` of the window, and the host/build log lines

## Code of conduct

Be decent. Don't be a jerk. Help newcomers.
