# swift-render for agents

Any agent that speaks MCP — Claude Code, Claude Desktop, Codex, Cursor — can make swift-render
videos through one stdio server, `swift-render-mcp`. It works in any Swift codebase, not only in
this repo. Agents without MCP can use the `swift-render` CLI directly ([below](#without-mcp-the-cli)).

## What the server does

The server picks a mode when it starts. Every tool reports the mode in its first line, and so do
`initialize` (`serverInfo.title`, `instructions`) and `list_scenes`.

| mode | when | what works |
|---|---|---|
| **project** | the working directory (or `$SWIFT_RENDER_ROOT`) is a swift-render project: a `swift-render.json`, a `Package.swift` that uses `SwiftRenderTool`, or an app whose `Launch/` was made by `init` | everything. Scene tools run the project's own CLI product and rebuild it when sources change. |
| **standalone** | any other directory, such as an app repo, a library or Claude Desktop's `/` | `docs`, `launch_film`, `init_project`, `get_props`/`set_props`, and the render tools on the built-in scenes (`AppleLaunch` and the demos). It uses the `swift-render` CLI next to the server binary (`$SWIFT_RENDER_CLI`, then `PATH`). Nothing is built in your directory. |
| **docs-only** | no project and no `swift-render` CLI found | `docs` and the resources; the other tools say how to fix it |

`init_project` turns a standalone server into a project one. It creates `<codebase>/Launch/`, and
from then on `new_scene`, `list_scenes`, the render tools and the review tools work there.

### The recipe (the server's `instructions`)

1. `docs {topic:"scenes"}` once. It is the scene API in two pages, and `docs {}` lists every topic.
2. To show off a Swift codebase, call `launch_film {preview:true}`. It scans the codebase and renders
   an Apple-style launch film, then returns the MP4 path, what it detected (with sources), the props
   file and a contact sheet. Fix copy with `launch_film {props:{"tagline":"…"}}`, then render
   without `preview`. Use `aspect:"9:16"` for the vertical cut.
3. To make your own film, call `new_scene {name}` (outside a swift-render package, call `init_project`
   first). Then write `body(at:duration:)` as a pure function of `t`.
4. Look after every edit with `contact_sheet {scene}` or `render_frames {scene, times}`. Data-driven
   scenes take `get_props` / `set_props`.
5. Run `check_scene` before finishing. It scans for blank frames, measures loudness and flags
   whoosh/riser sounds. Then `render_video {scene}` returns the MP4 path.
6. For review notes from people: `list_comments` → `get_comment` → `claim_comment` → edit →
   `render_frames {comment}` → `resolve_comment` (see [review-loop.md](review-loop.md)).

### Tools

| tool | arguments | does |
|---|---|---|
| `docs` | `topic?`: `index` `tools` `scenes` `timeline` `easing` `sound` `knobs` `launch` `looks` `cli` `review` `all` | the API guide (docs/ai-quickstart.md, compiled into the binary), one topic at a time |
| `launch_film` | `path?`, `aspect?`, `preview?`, `voiceover?`, `props?`, `rescan?`, `run_manifest?`, `open?` | scans the codebase and renders the AppleLaunch film into `<path>/out/`. Returns the film path, the scan table (each value with its source file, plus gaps), the props file `<path>/.swift-render/launch/<Name>.json` and a contact sheet. `props` merges keys into that file before rendering. |
| `new_scene` | `name`, `kind?` (`render`/`audio`) | scaffolds `<Name>.swift` in the project's scenes folder (auto-registered) and returns a short guide to writing it |
| `init_project` | `path?`, `local?`, `remote?`, `force?`, `run_manifest?` | runs `swift-render init`: `<path>/Launch/` with the film as Swift and a `launch` CLI. Depends on the swift-render checkout the server was built from, if any. |
| `get_props` | `scene`, `file?` | the props a data-driven scene renders (the saved props, the film's props or the defaults) |
| `set_props` | `scene`, `props`, `file?`, `replace?` | merges and saves props: `.swift-render/props/<Scene>.json`, or for `AppleLaunch` the film's props file, or a named variant `.swift-render/props/<Scene>/<name>.json` |
| `list_scenes`, `scene_info` | `scene` | what exists; clips, knobs and score with `file:line` |
| `render_frames`, `contact_sheet`, `check_scene` | `scene`, `times`…, `aspect?`, `props?`, `props_file?`, `comment?` | PNGs inline, so the agent can see them |
| `render_video` | `scene`, `preview?`, `aspect?`, `props?`, `props_file?` | `out/<Scene>[-9x16\|-1x1][-preview].mp4`, and returns its path |
| `set_knobs`, `build`, `list_comments`, `get_comment`, `claim_comment`, `reply_comment`, `resolve_comment` | | the review loop (project mode) |

Resources: `swift-render://docs/<topic>` (`resources/list`, `resources/read`) serve the same text as `docs`.

**Where files go.** `launch_film` and `init_project` write only inside the codebase they were pointed
at (`.swift-render/launch/`, `.swift-render/cache/`, `out/`, `Launch/`). Everything else writes inside
the project or workspace. Paths and names are validated:

- a scene name must be a Swift type name;
- `new_scene` names must be UpperCamelCase;
- `launch_film` / `init_project` paths must be existing directories, never `/`, your home folder or a
  system folder;
- `set_props` writes only under `.swift-render/props/` or `.swift-render/launch/`.

For a codebase outside the workspace, `Package.swift` is read as text rather than executed, unless you
pass `run_manifest: true`.

## Get the binaries

From a swift-render checkout, build both products. The server finds the CLI next to itself, and
`swift build` takes one `--product` at a time:

```bash
git clone https://github.com/skyblanket/swift-render && cd swift-render
swift build -c release --product swift-render
swift build -c release --product swift-render-mcp
echo "$(swift build -c release --show-bin-path)/swift-render-mcp"   # the path for the configs below
```

To put them on `PATH`, link both, so they stay side by side:

```bash
ln -sf "$(swift build -c release --show-bin-path)/swift-render-mcp" ~/.local/bin/
ln -sf "$(swift build -c release --show-bin-path)/swift-render" ~/.local/bin/
```

Other ways to get a server:

- **swift-render Studio.app** ships `swift-render-mcp` in `Contents/MacOS/`. It works in project mode.
  For standalone mode, also set `SWIFT_RENDER_CLI` to a `swift-render` binary.
- **The Claude Code plugin** (`claude-plugin/`) runs `bin/swift-render-mcp-launch`. The launcher uses
  `$SWIFT_RENDER_MCP`, `swift-render-mcp` on `PATH` or the Studio app. It builds from a project only
  when that project is trusted ([review-loop.md](review-loop.md#the-director-agent-skill-and-plugin)).

Requirements: macOS 14+ and Xcode 16 or later (see the README). The first render in a new `Launch/` package
builds it, which fetches swift-render.

## Configure your agent

In every snippet below, replace `/ABS/PATH/swift-render-mcp` with the path printed above. These
are snippets for you to paste. Nothing in this repo edits your client configs.

### Claude Code

```bash
claude mcp add swift-render -- /ABS/PATH/swift-render-mcp                  # this project
claude mcp add --scope user swift-render -- /ABS/PATH/swift-render-mcp     # every project
```

To share it with a team, add a project `.mcp.json` at the repo root:

```json
{
  "mcpServers": {
    "swift-render": { "command": "/ABS/PATH/swift-render-mcp" }
  }
}
```

Claude Code starts the server in the session's directory, which is how it finds the project or
workspace. The tools appear as `mcp__swift-render__<tool>`. In this repo, `.mcp.json` builds the
server from source on start. The plugin's tools are named `mcp__plugin_swift-render_swift-render__<tool>`.

### Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json` (Settings → Developer → Edit Config):

```json
{
  "mcpServers": {
    "swift-render": {
      "command": "/ABS/PATH/swift-render-mcp",
      "env": { "SWIFT_RENDER_WORKSPACE": "/Users/you/Code/MyApp" }
    }
  }
}
```

Desktop starts servers in `/`, so it has no workspace of its own. `SWIFT_RENDER_WORKSPACE` sets the
default codebase. Without it, pass `path` to `launch_film` / `init_project`, and renders outside a
project go to `$TMPDIR/swift-render-mcp/out/`. Restart Desktop after editing.

### Codex

In `~/.codex/config.toml`:

```toml
[mcp_servers.swift-render]
command = "/ABS/PATH/swift-render-mcp"
# A full-quality launch film or render can take minutes; the default tool timeout is much shorter.
tool_timeout_sec = 3600
```

Recent Codex CLIs can also run `codex mcp add swift-render -- /ABS/PATH/swift-render-mcp`. Codex
starts the server in the session's working directory.

### Cursor

`.cursor/mcp.json` in the project (or `~/.cursor/mcp.json` for every project):

```json
{
  "mcpServers": {
    "swift-render": {
      "command": "/ABS/PATH/swift-render-mcp",
      "env": { "SWIFT_RENDER_WORKSPACE": "${workspaceFolder}" }
    }
  }
}
```

If your Cursor version doesn't expand `${workspaceFolder}`, put the absolute path there instead.

### Environment

| variable | meaning |
|---|---|
| `SWIFT_RENDER_ROOT` | the swift-render project to use (project mode), wherever the server starts |
| `SWIFT_RENDER_WORKSPACE` | the codebase to use when the server starts somewhere else (Desktop, Cursor) |
| `SWIFT_RENDER_CLI` | the `swift-render` CLI for standalone mode (default: next to the server, then `PATH`) |
| `SWIFT_RENDER_MCP_TIMEOUT` / `_RENDER_TIMEOUT` / `_BUILD_TIMEOUT` | time limits in seconds for frames and sheets (180/600), renders and launch films (3600), and builds (1800) |

The server logs one line per call to stderr. stdout carries only the protocol.

## Without MCP: the CLI

Every tool above is a thin wrapper over the `swift-render` CLI, so a shell-only agent can do the
same. In a `Launch/` package, `swift run launch …` takes the same commands. These are the ten that
matter most:

```bash
swift-render launch ~/Code/MyApp --preview              # scan + film → MyApp/out/myapp-launch.mp4; props in MyApp/.swift-render/launch/MyApp.json
swift-render list --json                                # every scene: name, kind, defaultDuration, hasSoundtrack, hasProps
swift-render info <Scene> --json                        # clips (label, start/end, file:line), knobs, score events, captions
swift-render props <Scene>                              # default props JSON — edit, then pass --props file.json
swift-render new <Scene> [--kind audio]                 # scaffold an auto-registered scene
swift-render contact <Scene> --out sheet.png            # one image of the whole film: look at it
swift-render frame <Scene> --at 1.5,4 --out f.png       # frames at chosen times
swift-render check <Scene>                              # sheet + blank-frame scan + audio report (read it — you can't hear)
swift-render render <Scene> [--aspect 9:16] [--props p.json] [--preview] --out out/x.mp4 [--progress json]
swift-render init ~/Code/MyApp                          # MyApp/Launch/: your own scenes + a `launch` CLI
```

For comments, `swift-render review list|show|add|reply|status|scenes … --json` drives the review loop.
[ai-quickstart.md](ai-quickstart.md) is the API guide. It is the same text `docs` serves.

## Checking it works

```bash
python3 scripts/mcp-smoke.py --full    # this repo in project mode + a throwaway package outside it in standalone mode
swift test --filter 'MCP'              # MCPServerTests, MCPCreateTests (fake CLIs: modes, refusals, timeouts, cancels)
```
