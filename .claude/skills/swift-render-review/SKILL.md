---
name: swift-render-review
description: Work with swift-render review comments — timecoded, optionally region-boxed notes on a scene, stored in .swift-render/reviews/<Scene>.json and left from swift-render Studio, the `swift-render review` CLI or an agent. Use when asked to leave, list, read, address, reply to or resolve notes/feedback/comments on a swift-render scene or launch film, or to "do the review", "fix the notes", "address the feedback at 0:12".
---

# swift-render review comments

A review comment is a note on a scene at a time `t` (optionally a range `t…end`) and optionally a
region — a box on the frame, normalized 0–1 with the origin top-left. Comments have a thread of
replies and a status: `open` → `inProgress` (claimed, with an assignee) → `resolved` (with a
resolution and an after-frame) or `wontFix`. They live in `.swift-render/reviews/<Scene>.json`
(commit them), with frames in `.swift-render/attachments/`. Never edit those files by hand:
every writer (Studio, CLI, MCP) takes a file lock.

## Addressing comments (the usual job)

Delegate to the **swift-render-director** agent (`swift-render:swift-render-director` when it
comes from the plugin) — it runs the whole loop: list → look at the
frame, region and clip source → claim → edit the scene Swift → build → re-render and look →
resolve with a summary, or reply with a question and leave it open.

Doing it yourself, with the `swift-render` MCP tools (`mcp__swift-render__*` from a project
`.mcp.json`; `mcp__plugin_swift-render_swift-render__*` from the plugin):

| step | tool |
|---|---|
| what's open | `list_comments {scene?, status?}` — default open + inProgress |
| read + see it | `get_comment {id}` — thread, frame with the region boxed, active clips with `file:line` |
| start | `claim_comment {id}` — inProgress, assigned to you, before-frame captured |
| verify | `build {}`, `render_frames {scene, times, comment?, aspect?, width?}`, `contact_sheet {scene, comment?}`, `check_scene {scene, comment?}` — pass the comment id to render on the note's canvas (e.g. 9:16). A build past ~45 s answers "job jN": poll `render_status {job}` |
| ask | `reply_comment {id, body, attach_frame?, reopen?}` — the comment keeps its status unless `reopen` |
| finish | `resolve_comment {id, summary}` — renders + attaches the after-frame, marks resolved |
| tune | `set_knobs {scene, values}` — for values a scene exposes with `Knob.*` |

Rules that matter: scenes stay pure functions of `t` (no `@State`, `Timer`, `Date()`); no
whoosh/riser/swish sounds (use tick/rim/thump/blip/swell and harmony); in launch films (LaunchKit,
AppleLaunch, a `Launch/` package) no camera shake, no flash/white frames (never
`.transition(.flash())`) and no crash/boom — hard cuts on downbeats, one dissolve into the end card;
change only what the note asks; run `check_scene` on every scene you edited before finishing.

## From the terminal (no MCP)

The project's CLI renders in-process, so frames match the code on disk:

```sh
swift run swift-render review list [--scene S] [--status open,inProgress|active|all] [--json]
swift run swift-render review show <id> [--json]
swift run swift-render review add <Scene> --at 12.4 [--end 13] [--region 0.1,0.2,0.3,0.25] "logo feels small"
swift run swift-render review reply <id> "Scaled the logo 1.0 → 1.2 (LaunchFilm.swift:88)" --agent --attach-frame
swift run swift-render review status <id> resolved --resolution "logo +20%" --agent
swift run swift-render review frame <id> --out /tmp/c.png     # frame at t with the region boxed
```

Ids accept a unique prefix of 4+ characters. In a user's `Launch/` package the CLI product is
named in `swift-render.json` (`"product"`), e.g. `swift run launch review list`.

## Headless (what Studio runs)

In a project whose `.mcp.json` registers `swift-render` (this repo, or a `Launch/` package from
`swift-render init` — run it there):

```sh
claude -p "Address the open swift-render review comments on TimelineDemo." \
  --agent swift-render-director --mcp-config .mcp.json --permission-mode default \
  --allowedTools mcp__swift-render Edit Write MultiEdit NotebookEdit "Bash(swift build:*)" \
  --output-format stream-json --verbose --max-budget-usd 2
```

Not `acceptEdits`: it also auto-allows Bash `rm`/`mv`/`cp` and shell redirections, which Studio's
checkpoint can't see or revert. Plan and reply runs pre-approve only the read-only tools plus
`reply_comment` and deny the edit tools, Bash, `set_knobs`, `claim_comment`, `resolve_comment` and
`render_video`.

With only the plugin installed, the names are namespaced and there is no `--mcp-config`:
`--agent swift-render:swift-render-director --allowedTools "mcp__plugin_swift-render_swift-render"`
(plus the same edit tools and `"Bash(swift build:*)"` for a fix run).

See `docs/review-loop.md` for the event stream and the full flow.
