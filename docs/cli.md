# CLI reference

Run commands from the repository root with `swift run swift-render …`. In a package made by
`swift-render init` (or any package whose executable calls `SwiftRenderCommand.main(scenes:)`),
use that package's product instead, for example `swift run launch check MyAppLaunch`. Every
command below works there too. `swift-render --help` prints the short form of this page.

## Commands

| Command | What it does |
|---|---|
| `new <Scene> [--kind audio]` | Scaffold an auto-registered scene with a Timeline and a Score, in `Sources/SwiftRenderScenes/` or the `scenesDir` of `swift-render.json`. `--kind audio` makes an `AudioReactiveScene`. |
| `check <Scene>` | Contact sheet (`out/check-<Scene>.png`), blank-frame scan and an audio report: peak/RMS, loudness lane, silences, clipping, samples, voiceover, voice-vs-music level and a whoosh/riser warning. Read both before rendering. |
| `preview <Scene>` | Live window: scrub, play/pause, frame-step, synced audio. `--snapshot out.png` saves the window and exits. |
| `render <Scene>` | Render to MP4. The scene's own `Score` is synthesized and muxed unless `--audio` is given. |
| `frame <Scene> --at <t>[,t2,…]` | One PNG per time. |
| `contact <Scene> [--cols n] [--rows n]` | A labelled grid contact sheet (default 5×3), sampling shot midpoints. |
| `audio <Scene> --out score.wav` | Export the scene's `Score` as WAV. |
| `captions <Scene> --out film.srt\|.vtt` | Export the captions built from the scene's `speak` lines. |
| `props <Scene>` | Print a `PropsScene`'s default props as JSON. |
| `list [--json]` | Registered scenes. `--json` prints a `SceneSummary` array (name, kind, length, soundtrack, props, source path). |
| `info <Scene> [--json]` | Clips (label, start/end, `file:line`), knobs, score events by lane and captions. Also takes `--duration`, `--fps`, `--aspect`, `--props` and `--audio`. |
| `smoke` | One frame of every scene plus the no-swish audio check. CI runs it. |
| `launch [path]` | Scan a Swift codebase and render its launch film. See [below](#launch-and-init). |
| `init [path]` | Scaffold a `Launch/` package with the film as Swift and its own CLI. |
| `review <command>` | Timecoded review comments. See [below](#review). |
| `serve` | The render host behind Studio: JSON lines and binary frames on stdio. Not for interactive use; see [architecture.md](architecture.md). |
| `--help`, `--version` | Usage, or the version (`0.10.0`). |

## Scene options

These apply to `render`, `frame`, `contact`, `check`, `preview`, `audio`, `captions` and `props`
where they make sense.

| Option | Meaning |
|---|---|
| `--duration <s>` | Override the scene's default length. |
| `--fps <n>` | Frame rate, 1–240 (default 60). |
| `--aspect 16:9\|9:16\|1:1` | Output canvas (default 16:9: 1920×1080). |
| `--width <px>`, `--height <px>` | Custom size; overrides `--aspect`. |
| `--scale <n>` | Display scale. The Recorder encodes `size × scale`, so `--scale 2` gives 3840×2160. |
| `--out <path>` | Output file (default `out/render.mp4`). May not be empty, end in `/` or name a directory. |
| `--audio <path>` | Mux this file instead of the scene's score. Audio-reactive scenes analyze it. |
| `--props <file.json>` | Props for a `PropsScene`. Payloads must be complete: decoding does not apply Swift defaults. |
| `--knobs <file.json>` | Knob overrides for this run, used instead of `.swift-render/knobs/<Scene>.json`. |
| `--range <a:b>` | Render only seconds a…b, on the same frame grid as the full render. Picture only. |
| `--jobs <n\|auto>` | Render in parallel processes and stitch the pieces without re-encoding. `auto` uses half the cores. Frame-exact against a single-process render. |
| `--preview` | Half size, 30 fps. |
| `--open` | Open the result when done. |
| `--no-postfx` | Skip the global grain and vignette pass. |
| `--at <t>[,t2,…]` | `frame`: the times to render. |
| `--cols <n>`, `--rows <n>` | `contact`: grid size (1–64). |
| `--kind audio` | `new`: scaffold an audio-reactive scene. |
| `--snapshot <png>` | `preview`: save the window to a PNG and exit. |
| `--progress json` | `render`: `{"progress":{"frame":i,"total":n,"fps":f}}` lines on stderr, plus `{"stage":"audio"\|"render"\|"mux"}` lines around the frames. With `--jobs`, progress is summed across processes. Studio uses it. |

A valued option with no value, or a malformed value, exits with status 64.

Preview window keys: space play/pause, ←/→ one frame, ⇧←/⇧→ one second, Home to the start,
Esc or ⌘W to close.

Notes:

- `--range` is picture-only. Render the whole scene to keep its soundtrack (Studio muxes a
  matching slice with ffmpeg for range exports).
- `check` measures the mix you can't hear: *voice vs music* reports how many dB the voiceover sits
  above the ducked music while someone speaks, and the spans where it's buried.
- Render speed depends on the scene, the machine and the job count; measure before you promise a
  number.

## `launch` and `init`

```text
swift-render launch [path=.] [--out film.mp4] [--aspect 16:9|9:16|1:1] [--fps n] [--props-out props.json]
                    [--voiceover] [--preview] [--open] [--eject] [--rescan] [--no-render] [--no-manifest]
swift-render init   [path=.] [--local <swift-render checkout>] [--force] [--rescan] [--no-manifest]
```

| Option | Meaning |
|---|---|
| `--rescan` | Scan again and overwrite the kept props (`.swift-render/launch/<Name>.json`). |
| `--no-render` | `launch`: scan and write props only. |
| `--eject` | `launch`: also write the film as an editable `<Name>Launch.swift` into the scenes directory. |
| `--no-manifest` | Don't run `swift package dump-package` (for untrusted code). |
| `--props-out` | `launch`: also write the props to this path. |
| `--voiceover` | `launch`: add the generated voiceover lines. |
| `--local` | `init`: depend on a local swift-render checkout instead of the GitHub package. |
| `--force` | `init`: overwrite files the scaffold would write (it refuses otherwise). |

What the scanner reads, the props keys and the shot list are in [launch.md](launch.md).

## `review`

```text
swift-render review list   [--scene S] [--status open,inProgress|active|all] [--json]
swift-render review show   <id> [--json]
swift-render review add    <Scene> --at <t> [--end <t>] [--region x,y,w,h] [--author name] [--agent]
                           [--aspect 16:9|9:16|1:1] [--no-still] [--json] <body…>
swift-render review reply  <id> <body…> [--agent] [--author name] [--attach-frame] [--json]
swift-render review status <id> open|inProgress|resolved|wontFix [--resolution text] [--agent] [--author name] [--json]
swift-render review frame  <id> [--out path.png] [--max-width px]
swift-render review delete <id>
swift-render review scenes [--json]
```

Ids accept a unique prefix of four or more characters. Regions are normalized 0–1 from the top
left. The comment model and the agent loop are in [review-loop.md](review-loop.md).

## Environment

| Variable | Effect |
|---|---|
| `SWIFT_RENDER_ROOT` | The project to use, wherever the command runs. |
| `SR_3D_STATS=1` | Print the cost of each `Scene3D` render. |

The MCP server's variables are listed in [agents.md](agents.md#environment).
