# swift-render for agents

Any agent that speaks MCP — Claude Code, Claude Desktop, Codex, Cursor — can make swift-render
videos through one stdio server, `swift-render-mcp`. It works in any Swift codebase, not only in
this repo. Agents without MCP can use the `swift-render` CLI directly ([below](#without-mcp-the-cli)).

## What the server does

The server picks a mode when it starts. `initialize` (`serverInfo.title`, `instructions`),
`list_scenes` and `docs {}` report it on their first line; a tool that needs another mode says so
in its error, with the fix.

| mode | when | what works |
|---|---|---|
| **project** | the working directory (or `$SWIFT_RENDER_ROOT`) is a swift-render project: a `swift-render.json`, a `Package.swift` that uses `SwiftRenderTool`, or an app whose `Launch/` was made by `init` | everything. Scene tools run the project's own CLI product and rebuild it when sources change. |
| **standalone** | any other directory, such as an app repo, a library or Claude Desktop's `/` | `docs`, `launch_film`, `init_project`, `get_props`/`set_props`, and the render tools on the built-in templates (`AppleLaunch`, `KnobLab`, …; `list_scenes {all:true}` adds the demo films). It uses the `swift-render` CLI next to the server binary (`$SWIFT_RENDER_CLI`, then `PATH`). Nothing is built in your directory. |
| **docs-only** | no project and no `swift-render` CLI found | `docs` and the resources; the other tools say how to fix it |

`init_project` turns a standalone server into a project one. It creates `<codebase>/Launch/`, starts
its first build as a job, and from then on `new_scene`, `write_scene`, `list_scenes`, the render tools
and the review tools work there.

### The recipe (the server's `instructions`)

1. `docs {topic:"scenes"}` once. It is the scene API in two pages, and `docs {}` lists every topic.
2. To show off a Swift codebase, call `launch_film {preview:true}`. It scans the codebase and renders
   an Apple-style launch film, then returns the MP4 path, what it detected (with sources), the props
   file and a contact sheet. Fix copy with `launch_film {props:{"tagline":"…"}}`, then render
   without `preview`. Use `aspect:"9:16"` for the vertical cut.
3. To make your own film, call `new_scene {name}` (outside a swift-render package, call `init_project`
   first). Then write `body(at:duration:)` as a pure function of `t`: edit the file, or, in a client
   without file tools, send the whole source to `write_scene`.
4. Look after every edit with `contact_sheet {scene}` or `render_frames {scene, times}`. Data-driven
   scenes take `get_props` / `set_props`.
5. Run `check_scene` before finishing. It scans for blank frames, measures loudness and flags
   whoosh/riser sounds. Then `render_video {scene}` returns the MP4 path. Work that runs past ~45 s
   answers "job jN" instead: poll `render_status {job:"jN"}` until it says done ([below](#long-renders-jobs)).
6. For review notes from people: `list_comments` → `get_comment` → `claim_comment` → edit →
   `render_frames {comment}` → `resolve_comment` (see [review-loop.md](review-loop.md)).

### Tools

| tool | arguments | does |
|---|---|---|
| `docs` | `topic?`: `index` `tools` `scenes` `timeline` `easing` `sound` `knobs` `launch` `looks` `cli` `review` `contributing` `all` | the API guide (docs/ai-quickstart.md, compiled into the binary), one topic at a time |
| `launch_film` | `path?`, `any_folder?`, `aspect?`, `preview?`, `voiceover?`, `props?`, `rescan?`, `run_manifest?`, `open?`, `wait?` | scans the codebase and renders the AppleLaunch film into `<path>/out/`. Returns the film path, the scan table (each value with its source file, plus gaps), the props file `<path>/.swift-render/launch/<Name>.json` and a contact sheet. `props` merges keys into that file before rendering. |
| `new_scene` | `name`, `kind?` (`render`/`audio`) | scaffolds `<Name>.swift` in the project's scenes folder (auto-registered) and returns its source and a short guide to writing it |
| `write_scene` | `name`, `source`, `wait?` | creates or replaces `<Name>.swift` in the scenes folder with the whole source, builds, and returns the compiler diagnostics. For clients without file tools. |
| `init_project` | `path?`, `any_folder?`, `local?`, `remote?`, `force?`, `run_manifest?` | runs `swift-render init`: `<path>/Launch/` with the film as Swift and a `launch` CLI, then starts the first build as a job. Depends on the swift-render checkout the server was built from, if any. |
| `get_props` | `scene`, `file?` | the props a data-driven scene renders (the saved props, the film's props or the defaults) |
| `set_props` | `scene`, `props`, `file?`, `replace?` | merges and saves props: `.swift-render/props/<Scene>.json`, or for `AppleLaunch` the film's props file, or a named variant `.swift-render/props/<Scene>/<name>.json` |
| `list_scenes`, `scene_info` | `all?`; `scene`, `source?` | what exists; clips, knobs and score with `file:line` (`source: true` adds the scene's Swift) |
| `render_frames`, `contact_sheet`, `check_scene` | `scene`, `times`…, `aspect?`, `props?`, `props_file?`, `comment?` | PNGs inline, so the agent can see them |
| `render_video` | `scene`, `preview?`, `aspect?`, `props?`, `props_file?`, `wait?` | `out/<Scene>[-9x16\|-1x1][-preview].mp4`, and returns its path |
| `render_status` | `job?`, `wait?`, `cancel?` | progress and result of a job (see below); no `job` lists them |
| `set_knobs`, `build`, `list_comments`, `get_comment`, `claim_comment`, `reply_comment`, `resolve_comment` | | the review loop (project mode); `build` takes `wait?` |

Resources: `swift-render://docs/<topic>` (`resources/list`, `resources/read`) serve the same text as `docs`.

**Where files go.** `launch_film` and `init_project` write only inside the codebase they were pointed
at (`.swift-render/launch/`, `.swift-render/cache/`, `out/`, `Launch/`). Everything else writes inside
the project or workspace. Paths and names are validated:

- a scene name must be a Swift type name;
- `new_scene` / `write_scene` names must be UpperCamelCase and not a type SwiftUI, Foundation or
  swift-render already has (`Text`, `Score`, `Timeline`…), which would break the package's build;
- `launch_film` / `init_project` paths must be existing directories that look like a codebase
  (`Package.swift`, `*.xcodeproj`, `*.xcworkspace` or `.git`; `any_folder: true` waives that), never
  `/`, your home folder, a system folder, `~/Library`, a hidden folder or anything in a hidden folder
  of your home (`~/.ssh`, `~/.config/…`);
- `set_props` writes only under `.swift-render/props/` or `.swift-render/launch/`, `write_scene` only in
  the scenes folder. Every write is checked with only the project root symlink-resolved, so a symlink
  planted in the codebase (`.swift-render/props → elsewhere`) is refused rather than followed.

For a codebase outside the workspace, `Package.swift` is read as text rather than executed, unless you
pass `run_manifest: true`.

## Long renders: jobs

Some clients stop a tool call after about 60 seconds, whatever the server does: Claude Desktop
(the cap can't be configured, and progress notifications don't reset it), the Claude Code desktop
app, and the `cursor-agent` CLI. When they give up they cancel the call, which would kill the render
and leave no MP4. A full-quality launch film takes 15–60 s on an idle Mac and longer under load; a
93-second film, or the first build of a new `Launch/` package, takes minutes.

So `render_video`, `launch_film`, `build` and `write_scene` run their work as a **job**. The call
waits up to 45 seconds. If the job finishes by then, the call answers as usual. If not, it answers
with the job id, its progress and the planned output path, and the job keeps going:

```
render_video NeverHeard: still running after 45s as job j2 — it keeps going in the background.
status: j2 render_video NeverHeard · running · rendering 2700/5580 frames, 58 fps, ~49s left · 45s → /…/out/NeverHeard.mp4
next: render_status {job:"j2"} waits up to 30 s and reports progress; repeat until it says done …
```

`render_status {job:"j2"}` waits up to 30 seconds per call. Once the job is done it returns what the
tool would have returned: the film path, the contact sheet, the build diagnostics. `render_status {}`
lists every job, and `cancel: true` stops one. Scene tools that need a rebuild first (because sources
changed) wait for the build the same way. One job runs at a time, in order, and the server stops its
jobs when it exits.

- `wait: true` on those tools blocks until done. Use it in clients without a time limit.
- `wait: false` answers with the job id at once.
- `SWIFT_RENDER_MCP_DETACH_AFTER` sets the 45 seconds (`0` = always wait, the old behavior).
- When a request carries `_meta.progressToken`, the server also sends `notifications/progress`
  (frames rendered of the total) while the call waits. Clients that reset their timeout on progress
  can then wait longer. Claude Desktop does not.

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
default codebase. If it names no directory, `initialize` and `list_scenes` say so. Without it, pass
`path` to `launch_film` / `init_project`, and renders outside a project go to
`$TMPDIR/swift-render-mcp/out/`. Restart Desktop after editing.

Two Desktop limits to know:

- **Tool calls stop at about 60 seconds.** Use `preview: true` while iterating. Full renders and
  first builds come back as a job id after 45 s, and the agent polls `render_status` (see
  [Long renders](#long-renders-jobs)).
- **Desktop has no file-editing tools.** Launch films, props and the built-in templates need none.
  For your own scenes, the agent reads a scene with `scene_info {scene, source:true}` and writes it
  whole with `write_scene {name, source}`, which builds and returns the compiler errors. Adding a
  filesystem MCP server to Desktop works too.

### Codex

In `~/.codex/config.toml`:

```toml
[mcp_servers.swift-render]
command = "/ABS/PATH/swift-render-mcp"
# A full-quality launch film or render can take minutes; the default tool timeout is much shorter.
tool_timeout_sec = 3600
```

Recent Codex CLIs can also run `codex mcp add swift-render -- /ABS/PATH/swift-render-mcp`. Codex
starts the server in the session's working directory. To pin it, add `cwd = "/Users/you/Code/MyApp"`
to the table, or `env = { SWIFT_RENDER_WORKSPACE = "/Users/you/Code/MyApp" }`. Codex's default tool
timeout is 60 s: with `tool_timeout_sec` raised you can pass `wait: true` to the render tools;
otherwise long work comes back as a job. Contact sheets and frames are MCP image content; check that
your Codex version passes tool images to the model. If it doesn't, every answer still names the PNG
and MP4 paths.

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

If your Cursor version doesn't expand `${workspaceFolder}`, put the absolute path there instead. The
IDE allows long tool calls, but the `cursor-agent` CLI reportedly stops them at about 60 s, so long
renders come back as a job there; poll `render_status`.

### Environment

| variable | meaning |
|---|---|
| `SWIFT_RENDER_ROOT` | the swift-render project to use (project mode), wherever the server starts |
| `SWIFT_RENDER_WORKSPACE` | the codebase to use when the server starts somewhere else (Desktop, Cursor) |
| `SWIFT_RENDER_CLI` | the `swift-render` CLI for standalone mode (default: next to the server, then `PATH`) |
| `SWIFT_RENDER_MCP_TIMEOUT` / `_RENDER_TIMEOUT` / `_BUILD_TIMEOUT` | time limits in seconds for frames and sheets (180/600), renders and launch films (3600), and builds (1800) |
| `SWIFT_RENDER_MCP_DETACH_AFTER` | seconds a call waits for its job before answering with the job id (45; `0` = always wait) |

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
swift test --filter 'MCP'              # MCPServerTests, MCPCreateTests, MCPJobTests (fake CLIs: modes, refusals, jobs, cancels)
```
