---
name: swift-render-make
description: Make a video with swift-render (SwiftUI scenes rendered to MP4) through the swift-render MCP server or CLI. Use when asked for a launch film, promo, teaser, reel or any motion-graphics video of a Swift app or package, or to write, preview, tune or render a swift-render scene, in this repo or any other Swift codebase.
---

# Making videos with swift-render

swift-render renders SwiftUI scenes, which are pure functions of time, to MP4. The `swift-render`
MCP server does it from any Swift codebase. Its tools are `mcp__swift-render__*` from a project
`.mcp.json` or `claude mcp add`, and `mcp__plugin_swift-render_swift-render__*` from the plugin.
`list_scenes` and `docs {}` say the mode on their first line. **project** means scenes live here,
**standalone** means any other codebase with the built-in templates plus launch films, and
**docs-only** means there is no CLI yet (see docs/agents.md). A tool that needs another mode says so.

## The recipe

1. `docs {topic:"scenes"}` once, before writing any scene. `docs {}` lists the other topics:
   `timeline`, `easing`, `sound`, `knobs`, `launch`, `looks`, `cli`.
2. **Launch film of a codebase.** Call `launch_film {preview:true}`, with `path` when the codebase
   isn't the workspace. Look at the contact sheet it returns and read what it detected and what's
   missing. Fix copy with `launch_film {props:{"tagline":"…","features":[…]}}`. Never invent
   numbers. When it looks right, render without `preview`, and add `aspect:"9:16"` for the vertical cut.
3. **Your own scene.** Call `init_project` first when the codebase has no swift-render package, then
   `new_scene {name}`. Edit the returned file so `body(at:duration:)` is a pure function of `t`,
   using `Timeline`/`Clip`, `Ease.clip` and `Ease.spring`. Give it a `soundtrack(duration:)` with
   harmony and hits on the cuts. Without file tools (Claude Desktop), send the whole new source to
   `write_scene {name, source}`; it builds and returns the compiler errors.
4. **Look after every edit.** `contact_sheet {scene}` shows the whole film, and
   `render_frames {scene, times:[…]}` zooms in on moments. Iterate two or three times; scenes
   written blind look generic.
5. **Finish.** Run `check_scene {scene}`: blank frames, loudness, clipping, and whoosh/riser warnings
   (you can't hear it, so read the numbers). Then `render_video {scene}` and report the MP4 path it returns.

**Long work comes back as a job.** `render_video`, `launch_film`, `build` and `write_scene` answer with
"job jN" when they run past about 45 s (some clients stop a call at 60 s). The work keeps going. Call
`render_status {job:"jN"}` until it says done; it then returns the tool's result. Don't start the
same render again.

Data-driven scenes (`AppleLaunch`, any `PropsScene`) take `get_props {scene}` / `set_props {scene, props}`.
The saved props are what the render tools use. To try a change without saving it, pass `props` to
the render tool.

## Rules

- `body(at:)` stays pure: no `@State`, `Timer`, `Date()`, `onAppear`, `withAnimation` or unseeded
  randomness. Everything moves because `t` moves.
- No whoosh, riser or swish sounds. Mark cuts with `thump`/`rim`/`tick`/`blip`, or build into them
  with a chord `swell`, and write harmony (`chordPad`, `arpeggio`, `melody`), not only drums.
- Launch films (LaunchKit, AppleLaunch, a `Launch/` package) have no camera shake, no flash or white
  frames and no crash/boom. Cut hard on downbeats and use one focus-pull dissolve into the end card.
- Never hand-edit `.swift-render/reviews/*.json`. Review notes go through the review tools
  (the `swift-render-review` skill and the `swift-render-director` agent).

## Without the MCP server

The same steps work with the CLI (`swift run swift-render …` in this repo, `swift run launch …` in a
`Launch/` package, or a built `swift-render` anywhere):
`launch <path> --preview`, `new <Scene>`, `contact <Scene> --out sheet.png` (then read the PNG),
`frame <Scene> --at 1.5,4`, `check <Scene>`, `render <Scene> --out out/x.mp4`,
`props <Scene>` → edit → `--props file.json`, and `list --json` / `info <Scene> --json`.
