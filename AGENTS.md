# AGENTS.md

Guide for AI coding agents (Claude Code, Codex, Cursor, Gemini, …) working **with** or **on** swift-render.
Humans: start at [README.md](README.md).

swift-render makes videos from Swift. A scene is a SwiftUI view that is a pure function of time `t`; the engine
renders every frame to MP4 natively on the Mac (≈100–140 fps at 1080p). It also ships a native editor
(swift-render Studio), an MCP server, and a one-command launch film for any Swift codebase.

## Pick your interface

| You have… | Use | Start with |
|---|---|---|
| MCP support | `swift-render-mcp` (stdio) | [docs/agents.md](docs/agents.md) — config snippets for Claude Code, Claude Desktop, Codex, Cursor |
| A shell | the `swift-render` CLI | `swift run swift-render --help`; every query has `--json` |
| Swift code | the `SwiftRender` library | [docs/ai-quickstart.md](docs/ai-quickstart.md) |

## The 30-second recipes

**A launch film for a Swift codebase** (no code to write):

```bash
swift run swift-render launch /path/to/MyApp --preview --open      # scan → render; prints what it detected
swift run swift-render launch /path/to/MyApp --aspect 9:16          # vertical cut
```

Edit the generated `.swift-render/launch/<Name>.json` (title, tagline, features, colors), then render again.
For full control: `swift run swift-render init /path/to/MyApp` scaffolds a `Launch/` package with an editable scene.

**A new scene from scratch:**

```bash
swift run swift-render new MyFilm          # scaffold (auto-registered at build time)
swift run swift-render check MyFilm        # contact sheet PNG + report — READ BOTH before rendering
swift run swift-render render MyFilm --preview --open
swift run swift-render render MyFilm --out out/myfilm.mp4
```

**With MCP** (any agent, any Swift repo): call `docs` once for the API guide, `launch_film` to scan a codebase
and render its film (you get the film path and a contact sheet to look at), `get_props`/`set_props` to change its
words and colors, `new_scene` to start a scene, `render_frames`/`check_scene` to look, `render_video` to export.
Full tool table: [docs/agents.md](docs/agents.md).

**Address review comments** a human left in Studio: see [docs/review-loop.md](docs/review-loop.md)
(`swift-render review list --json`, or the MCP tools `list_comments → get_comment → claim_comment →` edit →
`resolve_comment`). In Claude Code, the `swift-render-director` subagent runs this loop.

## Rules that make output good (non-negotiable)

1. **Scenes are pure functions of `t`.** No `@State`, `Timer`, `Date()`, `withAnimation`, `.animation()`,
   `Task`, `onAppear`. Drive everything from `t` with `Ease.clip(t, start, end)` + an easing curve.
2. **Check before you render.** Run `check` (or the MCP `check_scene`/`contact_sheet`) and actually look at the
   PNG and the audio report. You cannot hear: the report's loudness lane and voice-vs-music line are your ears.
3. **No swish transitions.** Scores never use `whoosh`/`riser`; mark cuts with `tick`, `rim`, `thump`, `blip`,
   `swell` and harmony. `smoke` fails CI on noise sweeps.
4. **Launch-film grammar:** no camera shake, no white flash frames; big tight-tracked type, one accent color,
   springs damped ~0.6–0.85.
5. Name clips (`Clip(2.4) { … }.named("Hero")`) and expose tunables as knobs
   (`Knob.double("title.delay", 0.4, in: 0...2)`) so humans can comment on and tune them in Studio.

## Working on this repo

```bash
swift build                     # ≈20 s clean, ≈1 s incremental
swift test                      # ~420 tests; must stay green
swift run swift-render smoke    # one frame of every scene + house-rule audio check (CI)
python3 scripts/host-smoke.py   # render-host protocol
python3 scripts/mcp-smoke.py    # MCP server (add --full for the review loop and creation tools)
```

| Path | What |
|---|---|
| `Sources/SwiftRender/` | Engine: scene protocols, Timeline, Score/synth, Recorder, Knobs, introspection, LaunchKit + `AppleLaunch` |
| `Sources/SwiftRenderScenes/` | Demo films (where `swift-render new` puts scenes in this repo) |
| `Sources/SwiftRenderTool/` | The whole CLI as a library (`SwiftRenderCommand.main(scenes:)`), incl. `serve`, `launch`, `review` |
| `Sources/SwiftRenderCLI/` | This repo's `swift-render` executable: one line plus the generated scene registry |
| `Sources/SwiftRenderKit/` | Foundation-only shared model: project layout, review comments, host protocol, builds |
| `Sources/SwiftRenderStudio/` | The native editor (talks to `serve`; never links scene code) |
| `Sources/SwiftRenderMCP/` | The MCP server |
| `Plugins/` | Metal compiler + scene registry build plugins |
| `.swift-render/` | Per-project state: `reviews/` (commit), `knobs/` (commit), `props/`, `launch/`, `attachments/`, `cache/` (ignored) |

Conventions: Swift tools 5.10 (Swift 5 mode), macOS 14, **zero third-party dependencies**, doc comments on
public API, terse "why" comments, tests next to every behavior change. Keep `README.md`, `CHANGELOG.md` and the
relevant `docs/*.md` in sync with user-visible changes.

## Deeper docs

- [docs/README.md](docs/README.md) — the index of every guide
- [docs/architecture.md](docs/architecture.md) — targets, processes, data on disk, hot reload, the review loop
- [docs/cli.md](docs/cli.md) — every CLI subcommand and option
- [docs/ai-quickstart.md](docs/ai-quickstart.md) — the full scene API in one page (Timeline, easing, springs, Score, knobs, LaunchKit, media, captions, shaders, gotchas)
- [docs/agents.md](docs/agents.md) — MCP install/config for every client, tool list, CLI-only alternative
- [docs/launch.md](docs/launch.md) — `launch`, `init`, LaunchKit components, what the scanner reads
- [docs/review-loop.md](docs/review-loop.md) — comments, the director agent, the Claude Code plugin
- [docs/studio.md](docs/studio.md) — the editor, its keys and menus, its snapshot options for CI
- [docs/3d.md](docs/3d.md) — `Scene3D`
- [ROADMAP.md](ROADMAP.md)
