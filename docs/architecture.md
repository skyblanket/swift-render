# Architecture

swift-render is one Swift package with four libraries, three executables and two build plugins.
Everything that renders runs the project's own CLI, so Studio, the MCP server and the review loop
work on any package whose executable links `SwiftRenderTool`, not only on this repo.

## Targets

```
SwiftRenderKit      Foundation only. Project layout (.swift-render/), review comments + ReviewStore,
                    host wire protocol, SceneInfo, streaming builds + diagnostics, LaunchProps/Plan/Scanner
   ▲
SwiftRender         The engine: scene protocols, Timeline, Ease/Spring, Score + synth, Knob, introspection,
   ▲                Recorder + MP4Assembler, PostFX, components, LaunchKit + AppleLaunch, Scene3D, shaders
   │
SwiftRenderTool     The CLI as a library: SwiftRenderCommand.main(scenes:) — render/check/preview/…,
   ▲                serve, launch/init, review, --jobs
   │
SwiftRenderCLI      This repo's `swift-render` executable: one line + the generated scene registry
SwiftRenderScenes   The demo films (optional for library users)

SwiftRenderStudio   `swift-render-studio`, the native editor     ─┐ link only SwiftRenderKit;
SwiftRenderMCP      `swift-render-mcp`, the MCP server            ─┘ never the engine

Plugins/MetalCompilerPlugin   compiles Shaders/*.metal (falls back to prebuilt.metallib)
Plugins/SceneRegistryPlugin   registers every public scene struct of a CLI target and its same-package deps
```

Studio and the MCP server never import the engine. They build the project's CLI and talk to it,
which is why they keep working while your scene code is broken, and why a crash in a scene can't
take them down.

## Processes

| Process | Started by | Talks over | Job |
|---|---|---|---|
| `swift-render <cmd>` (or your product, e.g. `launch`) | you, CI, Studio's render queue, the MCP server | argv, stdout/stderr (`--progress json`) | renders, checks, frames, review commands |
| `swift-render serve` | Studio's `HostSupervisor` | stdin/stdout: JSON lines plus binary BGRA frames (`HostProtocol.swift`) | the live render host: `list`, `open`, `frame`, `stream`/`credit`, `setKnobs`, `setProps`, `still`, `check`, `cancel`, `shutdown` |
| `swift-render-studio` | you | child processes | the editor: builds, supervises the host, plays, records comments, runs exports and agent runs |
| `swift-render-mcp` | an MCP client (Claude Code, Desktop, Codex, Cursor) | newline-delimited JSON-RPC 2.0 on stdio | 21 tools: creation, rendering, jobs and the review loop |
| `claude -p --agent swift-render-director` | Studio's **Ask Claude…**, or you | stream-json on stdout | edits scenes through the MCP tools to resolve comments |

`render --jobs n` adds one more layer: the driver process starts `n` worker processes of the same
CLI, hands each the next piece of the film, and `MP4Assembler` stitches the pieces without
re-encoding.

## Data on disk

```
swift-render.json                      marks a project root: {"product", "scenesDir", "author"}
.swift-render/reviews/<Scene>.json     review comments and threads          commit
.swift-render/knobs/<Scene>.json       knob overrides (they change renders)  commit
.swift-render/props/<Scene>/…json      saved props variants
.swift-render/launch/<Name>.json       launch-film props (+ <Name>.scan.json evidence)
.swift-render/attachments/             before/after frames for comments
.swift-render/cache/                   scratch: MCP frames, contact sheets   gitignored
out/                                   renders, check sheets and reports      gitignored
.build/studio, .build/studio-release   Studio's debug (live) and release (export) builds
~/Library/Caches/swift-render/         tts/ (voiceover lines) and vision/ (VisionTrack analysis)
```

Every writer of a review file holds an `flock` on `.swift-render/reviews/.<Scene>.lock` and
writes atomically, so Studio, the CLI and the MCP server can edit comments at the same time.
Scene names map to one safe file name in every `.swift-render/` path.

## Hot reload

```
save Scene.swift
  → FileWatcher (Sources/, Plugins/, manifests, swift-render.json, assets/, .swift-render/{reviews,knobs})
  → BuildController: swift build --product <p> --scratch-path .build/studio   (one at a time, one queued)
  → HostSupervisor: start the new `<p> serve`, open the scene, warm the current frame
  → swap: the new host goes live, the old one shuts down          (≈2 s from save to new pixels)
```

A failed build keeps the last good host running and shows the diagnostics over the viewer. The
release build for exports lives in `.build/studio-release`, so it never waits on the live build.
Details: [studio.md](studio.md#how-it-works).

## Review loop

```
Studio / `review add` ──► .swift-render/reviews/<Scene>.json ◄── ReviewStore (flock)
                                     ▲
claude -p --agent swift-render-director
  └─► swift-render-mcp: list_comments → get_comment (frame + region + clip file:line) → claim_comment
        → edit the scene's Swift → build → render_frames (look) → resolve_comment (after-frame + summary)
                                     │
Studio watches the files: rebuilds while the agent edits, updates threads, Compare / Accept / Reopen
```

Before a fix run Studio takes a git checkpoint, so **Revert Run** can undo the agent's edits. The
MCP server rebuilds the CLI before a render only when something under `Sources/`, `Plugins/`,
`Package.swift` or `swift-render.json` is newer than the last build. Details:
[review-loop.md](review-loop.md).

## Determinism

A scene is a pure function of `t`. The Recorder renders frame `i` at `t = i / fps`, the score is
synthesized by a deterministic pure-Swift synth, PostFX grain is seeded, video frames decode with
zero tolerance, and `Scene3D` never reads SceneKit's clock. `swift test` renders twice and compares
bytes. Byte-identical output across machines, OS versions, fonts or toolchains is not promised.
