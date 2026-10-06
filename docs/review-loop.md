# The review loop

You watch a film in swift-render Studio, scrub to the beat that's off, draw a box on the frame and
type a note. Claude Code picks the note up, finds the code that draws that moment, edits it,
rebuilds, re-renders the frame and looks at it, then replies with what changed and resolves the
note. You compare before/after in Studio and accept or reopen.

```
 Studio / `swift-render review add`          .swift-render/reviews/<Scene>.json   (flock'd, commit it)
            │  comment: t, end?, region?, body, before-frame                ▲
            ▼                                                               │ ReviewStore writes only
 claude -p --agent swift-render-director ──► swift-render-mcp (stdio) ──────┤
            │   list → get (frame + box + clip file:line) → claim           │
            │   Edit scene .swift → build → render_frames (look) → resolve ─┘ after-frame + resolution
            ▼
 Studio watches the files: live rebuild while the agent edits, threads update, Compare / Accept / Reopen
```

The pieces:

| piece | where | what |
|---|---|---|
| comment model | `Sources/SwiftRenderKit/Review.swift` | `ReviewComment`, `ReviewStore` (flock'd read-modify-write), id/status/region parsing |
| frame helpers | `Sources/SwiftRenderKit/ReviewImage.swift` | region box, width cap, PNG — CoreGraphics/ImageIO only |
| CLI | `swift-render review …` (`Sources/SwiftRenderTool/ReviewCommand.swift`) | runs inside the project's CLI, renders in-process |
| MCP server | `swift-render-mcp` (`Sources/SwiftRenderMCP/`) | JSON-RPC 2.0 over stdio, Foundation + SwiftRenderKit only |
| agent | `.claude/agents/swift-render-director.md` | the film-director subagent that runs the loop |
| skill | `.claude/skills/swift-render-review/SKILL.md` | how any Claude Code session leaves/handles comments |
| plugin | `claude-plugin/` + `.claude-plugin/marketplace.json` | agent + skill + MCP server for other repos |
| smoke test | `scripts/mcp-smoke.py` | drives the server like Claude Code does; `--claude` runs the headless agent |

## Comments on disk

```
.swift-render/reviews/<Scene>.json        comments + threads, one file per scene   (commit)
.swift-render/attachments/<id>-before.png frame when the comment was made / first claimed
.swift-render/attachments/<id>-after-<replyID>.png   frame attached to a reply (resolve, --attach-frame)
.swift-render/knobs/<Scene>.json          knob overrides                           (commit)
.swift-render/cache/                      scratch: MCP frames, contact sheets       (gitignored)
```

- **Time**: `t` seconds from scene start; `end` makes it a range note ("this whole beat drags").
- **Region**: `{x, y, w, h}` normalized 0–1, origin top-left, against `canvas` (width × height @ fps).
- **Status**: `open` → `inProgress` (claimed; `assignee` set) → `resolved` (`resolution` + an
  after-frame on the closing reply) or `wontFix`. `acceptedBy` is a human's sign-off.
- **Reproduction**: `canvas`, `revision` (`git rev-parse --short HEAD`, `+dirty`), `source` (innermost
  clip at `t` when the engine reports clips), `context` (`knobs` JSON; `duration`/`aspect` only when
  the commenter pinned them). Frames are re-rendered on the comment's canvas with the project's
  *current* knobs and the scene's *current* length — the fix may be exactly a length change.
- Never edit the JSON by hand while Studio or an agent might be running; every writer holds an
  `flock` on `.swift-render/reviews/.<Scene>.lock`.

## `swift-render review`

Runs inside the project's CLI (`swift run swift-render review …` here; `swift run <product> review …`
in a `Launch/` package), so frames render in-process from the code on disk.

```sh
swift-render review list   [--scene S] [--status open,inProgress|active|all] [--json]   # default: active
swift-render review show   <id> [--json]
swift-render review add    <Scene> --at 12.4 [--end 13] [--region 0.1,0.2,0.3,0.25] [--author name] [--agent] \
                           [--aspect 9:16] [--no-still] [--json] "logo feels small"     # captures the before-frame
swift-render review reply  <id> "Scaled 1.0 → 1.2 (LaunchFilm.swift:88)" [--agent] [--attach-frame] [--json]
swift-render review status <id> open|inProgress|resolved|wontFix [--resolution text] [--agent] [--json]
swift-render review frame  <id> [--out x.png] [--max-width 960]   # frame at t, region boxed (default .swift-render/cache/frames/<id>.png)
swift-render review delete <id>                                   # comment + its attachment files
swift-render review scenes [--json]                               # registered scenes + active comment counts
```

Ids accept a unique prefix of 4+ characters. `--` ends options (for a body that starts with `-`).
`--json` prints `ReviewEntry` (`{"scene", "comment"}`), or an array of them for `list`.

## `swift-render-mcp`

Hand-written MCP over newline-delimited JSON-RPC 2.0 on stdio.

- `initialize` echoes the client's `protocolVersion` when it is one of `2024-11-05`, `2025-03-26`,
  `2025-06-18`, `2025-11-25`, else answers `2025-11-25`; `capabilities: {tools: {}}`;
  `serverInfo: {name: "swift-render", version}`; short `instructions`.
- Also `notifications/*` (never answered), `ping`, `tools/list`, `tools/call`, and JSON-RPC batches.
  Unknown methods → `-32601`, unknown tool → `-32602`, unparsable line → `-32700`; unknown fields
  are ignored. A failing tool returns a normal result with `isError: true` and the reason as text.
- **stdout is protocol only**: at start the server dups fd 1 for responses and points fd 1 at
  stderr. Logs go to stderr as `[swift-render-mcp] …` (one line per tool call with its time).
- **Project**: `$SWIFT_RENDER_ROOT`, else `Project.discover()` from the cwd (nearest
  `swift-render.json`, else `Package.swift`).
- **Rendering and introspection** shell out to the project's CLI product
  (`swift-render.json` `"product"`, default `swift-render`) with cwd = project root:
  `info --json`, `frame`, `contact`, `check`, `render`, `review scenes --json`. Before each call the
  server rebuilds that product (`ProjectBuilder.build`, default `.build`) only when something under
  `Sources/`, `Plugins/`, `Package.swift` or `swift-render.json` is newer than the last build — so
  after an agent edit, the next `render_frames` shows the edit, and a broken build comes back as an
  `isError` result with the compiler diagnostics.
- Review writes go through `ReviewStore` directly (no CLI needed).

### Tools (names are a contract with Studio and the director agent)

| tool | arguments | returns |
|---|---|---|
| `list_scenes` | — | one line per scene: kind, length, score/props, active comment count |
| `scene_info` | `scene` | clips (start–end, transition, `file:line`), knobs, captions, score events (first 80) |
| `render_frames` | `scene`, `times[]` (≤ 8), `width?` (160–1280, default 960) | a label + PNG per time, rendered at ≈`width` |
| `contact_sheet` | `scene` | grid PNG (≤ 1280 wide) |
| `check_scene` | `scene` | the `check` report (blank frames, loudness, clipping, whoosh/riser warning) + sheet PNG |
| `build` | — | `BUILD OK …` or `BUILD FAILED …` + `file:line:col: error: …` (`isError` on failure) |
| `list_comments` | `scene?`, `status?` (`open,inProgress` / `active` default / `all`) | each comment: id · scene · timecode · status · region · author, body, reply count |
| `get_comment` | `id` | `ReviewEntry` JSON; the clips active at `t` with `file:line` (or the scene source); current frame at `t` with the region boxed in pink (≤ 1280) |
| `claim_comment` | `id` | status `inProgress`, assignee `Claude` (agent); captures `<id>-before.png` if the comment has none. Refuses resolved/wontFix |
| `reply_comment` | `id`, `body`, `attach_frame?`, `reopen?` | agent reply; `attach_frame` renders + attaches the current frame (and returns it); `reopen` gives a claim back (inProgress → open) |
| `resolve_comment` | `id`, `summary` | renders the after-frame first (fails without changing anything if that fails), adds it on a reply with `summary`, status `resolved`, `resolution = summary`; returns the frame |
| `set_knobs` | `scene`, `values` (key → number/bool/string/null), `reset?` | merged overrides written to `.swift-render/knobs/<Scene>.json`; warns about keys the scene doesn't declare |
| `render_video` | `scene`, `preview?` | renders `out/<Scene>.mp4` (or `-preview.mp4`, half-res 30 fps) |

### Registering it

In this repo, `.mcp.json` (project scope) builds the server quietly to stderr, then execs it, so
stdout stays clean:

```json
{"mcpServers":{"swift-render":{"command":"sh","args":["-c",
  "swift build -q --product swift-render-mcp 1>&2 && exec \"$(swift build --show-bin-path)/swift-render-mcp\""]}}}
```

Claude Code starts it with the session's cwd (the project root), which is also how the server finds
the project. Elsewhere: `claude mcp add swift-render -- /path/to/swift-render-mcp`, or install the plugin.

## The director agent, skill and plugin

`.claude/agents/swift-render-director.md` (`name: swift-render-director`) is a film-director
subagent with a fixed loop — list → get_comment (look at the frame, box and clip source) → claim →
edit the scene Swift → build → render_frames and *look* → resolve with a `file:line` summary — and
fixed rules: one comment at a time, `body(at:)` stays pure, no whoosh/riser/swish (tick, rim, thump,
blip, swell and harmony instead), never touch other comments, ask (reply, leave open) when a note is
ambiguous, `check_scene` before finishing. Its `tools` are the 13 `mcp__swift-render__*` tools plus
`Read, Edit, Write, Glob, Grep, Bash(swift build:*)`.

`.claude/skills/swift-render-review/SKILL.md` teaches any session the comment model, the MCP tools,
the CLI, and to hand real work to the director.

**Plugin** (for repos other than this one): `claude-plugin/` holds `.claude-plugin/plugin.json`,
`agents/swift-render-director.md`, `skills/swift-render-review/SKILL.md`, `.mcp.json` and
`bin/swift-render-mcp-launch`. Install with

```
/plugin marketplace add skyblanket/swift-render
/plugin install swift-render@swift-render
```

The same commands from a shell are `claude plugin marketplace add skyblanket/swift-render` and
`claude plugin install swift-render@swift-render`. To try the plugin without installing it, run
`claude --plugin-dir /path/to/swift-render/claude-plugin`.

The launcher execs `$SWIFT_RENDER_MCP`, else builds `swift-render-mcp` from the project in the cwd
(or `./Launch`) — SwiftPM builds a dependency's executable product, so any package that depends on
swift-render works — else `swift-render-mcp` on `PATH`. Plugin MCP tools are namespaced
`mcp__plugin_swift-render_swift-render__<tool>` and the plugin's agent/skill are
`swift-render:swift-render-director` / `swift-render:swift-render-review`, so the plugin copy of the
agent differs from `.claude/agents` only in those tool prefixes (`ReviewLoopTests` keeps the two in sync).

## Headless run (what Studio executes)

cwd = project root:

```sh
claude -p "<prompt>" --agent swift-render-director --output-format stream-json --verbose \
  --permission-mode acceptEdits --allowedTools "mcp__swift-render" --mcp-config .mcp.json \
  --max-budget-usd 1
```

For fix runs (not just replies) also pre-approve builds — under `-p` an unapproved Bash call is
denied, while `acceptEdits` already covers Edit/Write: `--allowedTools "mcp__swift-render"
"Bash(swift build:*)"`. Optional: `--append-system-prompt "<house rules>"`, `--model`,
`--resume <session_id>` to continue a thread after Reopen, `--include-partial-messages` for token deltas,
`--strict-mcp-config` to skip the user's other MCP servers (observed: it also drops plugin servers, so
use it only with `--mcp-config`).

The verification prompt was: *List the open swift-render review comments and reply to `<id>` with
the word ack. Do not edit any files.* `python3 scripts/mcp-smoke.py --claude` runs it: it adds a throwaway
comment with `swift-render review add`, runs the command above, checks that an agent reply containing
"ack" landed in `.swift-render/reviews/TimelineDemo.json`, prints every event, and deletes the comment.

### stream-json events, as observed (Claude Code 2.1.284)

One JSON object per stdout line. Decode with optionals everywhere and ignore unknown types/fields.

- **`{"type":"system","subtype":"init"}`** — first line, before any API call. Observed keys:
  `session_id`, `cwd`, `model`, `permissionMode`, `tools` (the effective tool list), `mcp_servers`
  (`[{name, status: "connected"|"pending"|"failed", source: "dynamic"|"project"|"plugin"|"user"}]`),
  `agents`, `skills`, `plugins` (`[{name, path, source, version}]`), `slash_commands`, `apiKeySource`,
  `claude_code_version`, `output_style`, `uuid`, … With `--agent swift-render-director` and
  `--mcp-config .mcp.json`, `tools` was exactly the 13 `mcp__swift-render__*` tools + `Read, Edit, Write,
  Bash` and `swift-render` was `connected` (source `dynamic`). 2.1.284 has no `Glob`/`Grep` tools (they
  are ignored in the agent's list), and `Bash(swift build:*)` shows up as plain `Bash`.
- **`{"type":"assistant","message":{"content":[…]}}`** — `content[]` holds `{type:"text",text}` and
  `{type:"tool_use",id,name,input}`; file edits carry `input.file_path`, shell calls `input.command`.
  Observed (auth failure): `message.model:"<synthetic>"`, top-level `error:"authentication_failed"`,
  `is_api_error_message:true`, `session_id`, `uuid`, `timestamp`, `parent_tool_use_id`.
- **`{"type":"user","message":{"content":[{type:"tool_result",tool_use_id,content}]}}`** — tool results
  (not observed in this environment; see below).
- **`{"type":"result"}`** — last line. Observed keys: `subtype`, `is_error`, `result` (final text),
  `total_cost_usd`, `duration_ms`, `duration_api_ms`, `num_turns`, `session_id`, `usage`, `modelUsage`,
  `permission_denials`, `terminal_reason` (`"api_error"`), `stop_reason`. **Check `is_error`, not
  `subtype`**: the not-logged-in run ended with `subtype:"success"`, `is_error:true`, exit status 1.

Gotchas seen while verifying:

- When the environment has `MCP_CONNECTION_NONBLOCKING=true` (e.g. launched from inside Claude
  Desktop), project and plugin MCP servers can still be `pending` at `system/init` and missing from
  `tools`; the `--mcp-config` server was connected regardless. Studio should spawn `claude` with its
  own login-shell environment (or `MCP_CONNECTION_NONBLOCKING=false`).
- In the swift-render repo the project `.mcp.json` server and `--mcp-config .mcp.json` are the same
  server name; init lists one `swift-render`.

### What was verified, and what wasn't

- `python3 scripts/mcp-smoke.py --full`: initialize/version negotiation, notifications, ping,
  tools/list, error codes, every tool except `render_video`, a full add → get → claim → reply → resolve
  round trip, and the review file contents — all against the real server launched through `.mcp.json`.
- `swift test --filter ReviewLoopTests`: Kit helpers, `swift-render review` round trip with real
  in-process renders, the server binary over stdio, and agent/skill/plugin consistency.
- The headless command above, run for real: it parsed every flag, loaded the agent with exactly the
  intended tools, and connected the MCP server — then stopped at **"Not logged in · Please run /login"**
  because the `claude` CLI on the verification machine had no credentials (`claude auth status` →
  `loggedIn: false`). The model turn (list → reply "ack") and the `user`/`tool_result` events are
  therefore **not yet observed**: run `claude auth login`, then `python3 scripts/mcp-smoke.py --claude`.
- The plugin, via `--plugin-dir ./claude-plugin`: plugin, agent (`swift-render:swift-render-director`) and
  skill load; its MCP server connects through the launcher and the agent's tools resolve to the 13
  `mcp__plugin_swift-render_swift-render__*` tools. `claude plugin validate` passes for
  `claude-plugin/` and the marketplace (it checks manifests only, not agent/skill front matter).
- The plugin launcher, run from an app repo after `swift-render init` (so a `Launch/` package
  depends on swift-render): it built `swift-render-mcp` from `./Launch`, and the server answered
  `initialize` and listed all 13 tools. The `marketplace add` / `install` commands were not run,
  because they change the user's Claude Code configuration.
