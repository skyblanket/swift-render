# Changelog

## Unreleased

### Documentation
- `docs/README.md` is one index for every guide; new `docs/architecture.md` (targets, processes,
  data on disk, hot reload, the review loop); `docs/cli.md` covers every subcommand and option;
  `docs/agents.md` lists all 21 MCP tools with their arguments; `docs/studio.md` lists every key
  and menu.
- Doc comments on every public declaration in `SwiftRender`, `SwiftRenderKit` and
  `SwiftRenderTool`.
- Removed unreferenced screenshots from `docs/assets/`.

## 0.10.0 — 2026-10-15

"Studio preview". This release makes swift-render a way to make Apple-style launch films for Swift
codebases. It adds a native editor and an agent review loop on top of the engine.

### Added
- **True 3D: `Scene3D`** (`Sources/SwiftRender/ThreeD/`). A SceneKit scene rendered offscreen with
  `SCNRenderer` at the frame's real pixel size (layout × display scale) and returned as an image.
  It composites with SwiftUI, shaders and PostFX. You describe the scene from `t` with a small
  value API, and every property is set every frame:
  - Primitives: `Box3D`, `Sphere3D`, `Plane3D`, `Cylinder3D`, `Cone3D`, `Torus3D`, `Capsule3D`,
    extruded `Text3D`, the rounded device `Slab3D` (with a `screen:` panel), `Floor3D` and
    `Group3D`.
  - `Model3D` loads USDZ, OBJ, SCN and DAE through `AssetPaths` from cached templates, with
    `fit:`/`anchor:`. Named parts are posed with `.part("Arm") { … }`.
  - PBR `Material3D` with presets, normal and AO maps, clear coat, and `Texture3D.view { }`, which
    textures a surface with any SwiftUI view rendered at `t`.
  - `Light3D` directional, spot, omni, area, ambient and `studioRig`, with soft shadows. A
    procedural HDR studio environment by default, or `.file("x.exr")`.
  - Backgrounds: `.color`, a SwiftUI `.view` drawn inside the 3D frame (so DOF and shadow
    catchers work), `.transparent` and `.environment`.
  - `Camera3D` with FOV, depth of field, `orbit`, `lerp`, `dolly`, `spring` and `dollied`.
    `Motion3D.turntable`/`easedTurntable`/`oscillate`/`hover`.
  - `Fog3D` and `Effects3D` (HDR, exposure, bloom, SSAO, vignette).
  - SceneKit's clock is never used: the scene is paused, there's no jitter or TAA, exposure
    adaptation and motion blur are off, and embedded model animations are removed.
  - The same `t` gives bit-identical pixels, independent of render history and across processes.
    A scene re-created in the same process stays within PSNR ≥ 45 dB (SceneKit re-seeds its
    sampling noise). See [docs/3d.md](docs/3d.md).
- **`Showcase3D` demo**: a titanium device with a live SwiftUI screen, studio light, an eased turn
  and dolly, depth of field, a soft floor shadow and a score. The 3D layer costs ≈18–19 ms/frame at
  1080p (release). `SR_3D_STATS=1` prints the Scene3D cost.
- **Fast, honest exports in Studio.** Exports use a release CLI built once in
  `.build/studio-release` (skipped while it's newer than every source) and `--jobs auto` for whole
  films. `render --progress json` adds `{"stage":"audio"|"render"|"mux"}` lines, and `--jobs`
  overlaps the final soundtrack synthesis with the chunks. The Exports popover shows a native
  spinner for early steps, a native progress bar once frames flow, and one plain status line.
- **Right-click menus, Delete and Undo in Studio.** Comments (list row, viewer pin, lane marker,
  thread), replies, scenes, sidebar sections, exports, clips, the ruler, the picture, knobs,
  content fields and Claude's transcript each have a standard Mac context menu built from one
  menu model (`ContextMenus`), with the same commands as VoiceOver actions. Deletes ask first,
  files go to the Trash (confined to the project) and Edit › Undo reverses every delete and
  Trash move. ⌫ deletes the selected comment, Edit › Copy copies it. Snapshots take
  `--context-menu <kind>` and `--confirm <kind>`. `SceneSummary` gains `sourcePath`.
- **`swift-render launch [path]`** scans a Swift codebase offline: `Package.swift` (via
  `dump-package`, or `--no-manifest` for untrusted code), `.xcodeproj`, `AppIcon`/`AccentColor`,
  `Info.plist`, README, CHANGELOG, LICENSE, git and screenshots. It prints each value with its
  source, plus any conflicts and gaps, and writes `.swift-render/launch/<Name>.json` (and
  `<Name>.scan.json`). It then renders the `AppleLaunch` scene to `out/<name>-launch.mp4`.
  Options: `--aspect 9:16|1:1`, `--preview`, `--voiceover`, `--rescan`, `--no-render`, `--eject`,
  `--props-out`. See `docs/launch.md`.
- **`swift-render init [path]`** scaffolds `<path>/Launch/`, a package that depends on
  swift-render (`from: "0.10.0"`, or `--local <checkout>`). It contains your film as
  `Sources/LaunchScenes/<App>Launch.swift`, a `launch` CLI, `swift-render.json` and `.mcp.json`.
- **LaunchKit** (`Sources/SwiftRender/LaunchKit/`) provides Apple-keynote-grammar components, each
  pure in a local `t`: `LaunchTheme`, `Motion`, `.reveal`, `.specularSweep`, `.launchPostFX`,
  `Stage`, `Eyebrow`, `KeynoteTitle`, `LaunchIcon`, `AppIconHero`, `GlassPanel`, `DeviceFrame`,
  `ScreenshotView`, `FeatureCard`/`FeatureTriad`/`FeatureList`, `SwiftHighlighter`, `CodeReveal`,
  `TerminalCard`, `StatCounter`/`StatRow`, `ChangelogList`, `PlatformBadges`, `EndCard` and
  `LaunchScore`. The new transitions are `.focusPull` and `.zoomThrough`. Components that make a
  sound expose their timing (`landTimes`, `lineTimes`, `keystrokeTimes`, `rowTimes`).
- **`AppleLaunch`** is a built-in `PropsScene` that every CLI built on `SwiftRenderTool` has. It
  sizes itself to the props through `LaunchPlan`, using whole bars on a 60 fps beat grid. Set
  `"typeface": "inter"` to use the bundled Inter (SIL OFL) for commercial renders.
- **swift-render Studio** (`swift-render-studio`) is a native macOS editor. It builds the
  project's CLI into `.build/studio` and runs it as a render host, with a blue/green swap on each
  build, so hot reload takes about 2 s. Features:
  - timeline lanes for clips (with `file:line`), score events, loudness, captions and comments
  - viewer with 16:9 / 9:16 / 1:1 canvases, safe-area guides and A/B compare
  - comments with a time range and a region box
  - inspector: live knobs, props JSON editor and the check report
  - agent panel that runs headless Claude Code, with git checkpoints and Revert
  - render queue with presets: Master 1080p60, 4K, 9:16, 1:1, App Store previews (15–30 s
    enforced), preview and GIF
  - **New Launch Film…**
  - offscreen `--snapshot` for CI

  `scripts/package-studio.sh` builds a signed `swift-render Studio.app` whose icon is rendered by
  swift-render (`StudioAppIcon`). See `docs/studio.md`.
- **`swift-render serve`** is the render host behind Studio. It speaks JSON lines plus binary
  frames on stdio (`list`, `open`, `frame`, `setKnobs`, `setProps`, `stream`, `credit`, `cancel`,
  `still`, `check`, `shutdown`). It coalesces scrubbing, streams playback and caches score audio.
  `scripts/host-smoke.py` drives it over real pipes.
- **Review loop:**
  - `swift-render review list|show|add|reply|status|frame|delete|scenes` manages timecoded
    comments, which can have a range and a region box. They are stored in
    `.swift-render/reviews/<Scene>.json` (file-locked, meant to be committed), with before and
    after frames in `.swift-render/attachments/`.
  - `swift-render-mcp` is a hand-written MCP stdio server. It returns rendered frames inline and
    rebuilds the project before rendering when sources changed.
  - `.claude/agents/swift-render-director.md` is the film-director subagent.
  - `.claude/skills/swift-render-review` is a skill for working with review comments, and
    `.claude/skills/swift-render-make` one for making videos.
  - `.mcp.json` registers the MCP server in this repo.
  - A Claude Code plugin (`claude-plugin/`) and marketplace entry (`.claude-plugin/`) bring the
    agent, skill and server to other repos.
  - `scripts/mcp-smoke.py` (`--full`, `--claude`) exercises the server.
  - See `docs/review-loop.md`.
- **Engine introspection:**
  - clips record their `file:line` and take `.named("…")` labels
  - `Timeline(t, label:)` names nested lanes
  - transitions carry a name
  - `Knob.double/bool/text/color` are live-tunable constants, with overrides in
    `.swift-render/knobs/<Scene>.json`
  - score events are sorted into lanes (`Score.eventInfos`)
  - `swift-render info <Scene> [--json]` reports all of this
- `PropsScene` / `PropsAudioScene` can implement `duration(for:)` and
  `soundtrack(duration:props:)`, so the data decides the length and the score.
- CLI: `render --knobs file.json`, `render --progress json` (machine-readable progress on
  stderr), `list --json`, and `Recorder.render(progress:)`.
- `swift-render.json` marks a project root (`product`, `scenesDir`, `author`). `new` scaffolds
  into `scenesDir`.
- `KnobLab` (knobs reference scene) and `StudioAppIcon`.
- **Videos from any agent in any Swift repo.** `swift-render-mcp` has 21 tools. Besides the review
  loop it can make videos: `docs` (the API guide, compiled in), `launch_film`, `init_project`,
  `new_scene`, `write_scene` (for clients without file tools), `get_props`/`set_props` and
  `render_video`. It runs in *project*, *standalone* (any codebase, built-in templates, the
  `swift-render` CLI next to the server) or *docs-only* mode. Renders, launch films and builds
  that take longer than 45 s continue as jobs that `render_status` reports on, so clients that
  stop tool calls at ~60 s (Claude Desktop, `cursor-agent`) still get the film. Paths and scene
  names are validated and writes are confined to the project. See `docs/agents.md`.
- `AGENTS.md` and `CLAUDE.md`: a one-page guide for coding agents working with or on swift-render.
- The 0.10 teaser film (`docs/assets/macro-film.mp4`, a GIF in the README).

### Changed
- **Studio playback is faster.** Frames go to the screen through a zero-copy IOSurface path; the
  host answers `open` with the first frame and probes the scene afterwards, keeps visited scenes
  warm and pipelines quick scene switches; playback runs at the scene's fps with a larger frame
  cache and a quality ladder that steps down (half size, then a lower frame rate) and back up.
- **Studio's look**: one accent, native controls, Claude as a teammate in the panel, neutral
  timeline lanes, and a sidebar that groups scenes into Templates, Music-driven and Films with a
  filter field.
- **`render --jobs`** cuts the film into small pieces (up to 4 per process) that processes take as
  they finish, instead of equal slices, so one heavy stretch no longer holds up the export. A
  failed piece stops the others at once and names the piece.
- CI runs on `macos-26` (Xcode 26, the toolchain Studio targets).
- **The CLI is a library.** `SwiftRenderTool` exposes `SwiftRenderCommand.main(scenes:)`, and
  `SceneRegistryPlugin` is an exported product. It scans the CLI target plus its same-package
  dependencies. Any package can now ship its own `swift-render`-style executable, and
  `SwiftRenderCLI` is a one-line `main.swift`.
- New Foundation-only **`SwiftRenderKit`** library: project layout, review model, host protocol,
  `SceneInfo`, streaming builds and diagnostics, and `LaunchProps`/`LaunchPlan`/`LaunchScanner`.
  The engine depends on it, and Studio and the MCP server depend on nothing else.
- `Recorder.Config.outputSize` defaults to `size × scale` (rounded to even). `--scale 2` now
  encodes 3840×2160, and `--preview` encodes at half size.
- The Recorder converts frames into its own pooled pixel buffers instead of going through
  `CIContext`. That takes about 0.7 ms per 1080p frame, down from 1.2–2 ms, and the output is
  byte-identical to before.
- `Transition` has a public `init(_ name:duration:apply:)` and a `name`, so custom transitions
  can be built outside the module and show up by name in Studio. SwiftUI also has a `Transition`,
  so write `SwiftRender.Transition` when you name the type.
- **Clip times come from each Timeline's fitted clock.** The probe records every (scene time,
  local time) pair a `Timeline` is seen at and fits a piecewise-linear clock through them, so
  `Timeline(t * speed)`, clamped clocks like `Timeline(max(0, t - k))` and nested retimed
  Timelines report where their clips are actually on screen (a clamp's held first frame counts,
  so `Timeline(max(0, t - 1))`'s first clip spans 0–3, not 1–3). Clip content is only evaluated
  inside its visible span and local `0..<length`, so clips never on screen (starting after the
  end, NaN length) no longer appear; a Timeline built only to read `.duration` no longer shows up
  as phantom clips; a NaN or infinite duration gives an empty structure; and the structural pass
  is capped at 4096 content evaluations, breadth-first.
- **Knob overrides are read leniently**: a number for a text knob reads as `"2026"`, a bool as
  text, a finite numeric string as a number, and `0`/`1` or `"true"`/`"false"` (any case) as a
  bool. Other mismatches keep the default, visible as `KnobInfo.value`.
- `MP4Assembler.assemble` takes `audioOffset:`, and `Recorder.render(startTime:audioURL:)` plays
  scene-timed audio from `startTime`, in sync with the first frame of a range render.
- **CLI input is validated.** A valued option with no value or a malformed value exits 64.
  `--out` and `--snapshot` may not be empty, end in `/`, or name an existing directory (an empty
  `--out` used to delete the working directory). `--aspect` accepts only `16:9`, `9:16` or `1:1`.
  `render --jobs N --progress json` prints aggregated progress.
- `Project.discover`: an explicit folder wins over `SWIFT_RENDER_ROOT`, and an app root whose
  `Launch/` holds `swift-render.json` resolves to `Launch/`. Scene names map to one safe file name
  in every `.swift-render/` path.
- Review: any status change, or a different resolution text, clears `acceptedBy`; claim, resolve
  and reply-reopen re-check the status under the review lock; an unreadable review file is
  reported instead of silently hiding its comments.
- **swift-render-mcp**: `render_frames`, `contact_sheet` and `check_scene` take `comment` (render
  on that note's canvas) and `aspect`. Scene arguments must be Swift type names; times must be
  finite and within 0…86400 s. `set_knobs` fails for an unknown scene or a value of the wrong type for a declared knob, and never overwrites a knob
  file that isn't valid knob JSON. `initialize`/`ping`/`tools/list` answer immediately, other calls
  run on a serial worker with time limits (`SWIFT_RENDER_MCP_TIMEOUT`,
  `SWIFT_RENDER_MCP_RENDER_TIMEOUT`, `SWIFT_RENDER_MCP_BUILD_TIMEOUT`, `SWIFT_RENDER_MCP_EOF_GRACE`),
  and `notifications/cancelled` kills the call's process group.
- The plugin launcher no longer builds code from the current directory by default: it runs
  `$SWIFT_RENDER_MCP`, then `swift-render-mcp` on `PATH`, then the server in `swift-render
  Studio.app`, and builds in the project only when it is trusted (`SWIFT_RENDER_MCP_BUILD=1` or
  `~/.config/swift-render/trusted-projects`).
- Launch-film house rules (no shake, no flash or white frames, no crash or boom) are shared by the
  MCP instructions, Studio's agent prompt, the director agent and the skill.
- **Studio agent runs** use `--permission-mode default` (never `acceptEdits`, which also allows
  Bash `rm`/`mv`/`cp`): fix runs pre-approve the swift-render tools, the edit tools and
  `Bash(swift build:*)`; plan and reply runs get only the read-only tools plus `reply_comment`.
- **Revert Run** backs up current content to `refs/swift-render/pre-revert/<run>` first, keeps
  files edited after the run unless you pick *Revert All, Discard Later Edits*, trashes only files
  that did not exist at checkpoint time, and matches paths literally.
- Studio exports write a hidden `.partial` file and replace the destination only on success.
- Studio's file watcher acts only on `Sources/`, `Plugins/`, the manifests, `assets/` and
  `.swift-render/{reviews,knobs}`; `.claude/` worktrees, nested `.build` folders, `Tests/` and
  `scripts/` no longer trigger rebuilds. `--knob`/`--props`/`--check` apply without `--tab`, and
  `--scene X` loads X's saved knobs.
- **`init` never clobbers**: it refuses when any file it would write exists (`--force` overwrites
  and lists each file), reuses the kept props at `.swift-render/launch/<Name>.json` unless
  `--rescan`, and copies icons and screenshots only from inside the project.
- **LaunchKit**: `--aspect 1:1` is a stacked square layout instead of a letterboxed 16:9 film; the
  terminal shot is 2–4 bars, sized to its session (at most 3 commands, 3 output lines each, 8 lines
  in all); feature details are capped at 80 characters; headline lines share one fitted size;
  `KeynoteTitle.lineStart` no longer adds 0.12 s, so shots are on screen on their cut. New API:
  `LaunchTerminal`, `LaunchScanner.contained(_:in:)`, `LaunchLayout.isSquare`/`.stacks`,
  `LaunchScore.Cue.terminalSpeed`/`heroSweep`/`heroName`/`heroTagline`,
  `LaunchTheme.displayNSFont`/`displayWidth`/`fittedDisplaySize`, `TerminalCard.fittedFontSize`,
  `FeatureCard(detailLines:)`, `CodeReveal(maxHeight:)`.
- `launch` writes `out/.gitignore` (`*`) when it creates the default `out/`. The scanner detects
  SwiftPM `@main` App executables as apps, reads `.github/screenshots` and CRLF files, and skips a
  `Launch/` scaffold.

### Fixed
- `--scale` and `--preview` used to encode at the base size, rendering at the reduced scale and
  then resampling up. Half-res previews now really are 960×540.
- README and quickstart scene templates now `import SwiftRender` (scenes live outside the engine
  module since 0.9), and the README's `Hello` returns its view explicitly, so the snippet
  compiles.
- `docs/studio.md` pointed at the wrong path for `StudioAppIcon.swift`.
- `launch --eject` in this repo failed: it looked for the pre-0.9 `Sources/SwiftRender/Scenes`.
  It now writes into `Sources/SwiftRenderScenes`, and the ejected file's usage comment names the
  project's CLI product.
- The launch scanner sentence-cased product names in changelog items and feature details
  (`Swift-render launch`); names spelled lowercase on purpose (the product's own name, `iOS`,
  `config.json`, `v2`) are left alone.
- Probe: content was called at times the render never reaches, which trapped on scenes like
  `RecHUD` (`for: .infinity`) in `info`, `serve` and `review add`; a Timeline's offset was locked in
  from its first sighting; NaN durations hung and infinite ones trapped.
- Engine caches (samples, images, video) are keyed by file size, modification time and inode, so
  an edited file is decoded again. A failed TTS line or sample is never cached as a voiceless mix,
  and the host sends a warning instead.
- Path traversal through scene names, attachment paths and comment ids; `KnobFile.save` replacing
  a broken file; the host crashing on huge `t`, non-finite stream ranges or huge credits;
  `--jobs` reading `CommandLine.arguments` instead of the arguments passed in.
- MCP calls could hang forever; `render_frames` with `nan`/`inf` crashed the server.
- Studio: overlapping builds could leave an orphaned `serve` or put an older build live; changes
  made during a swap were lost; the crash card used the playhead instead of the crashing frame;
  `openStream` didn't send `fps`; a failed or cancelled export deleted the file it was replacing;
  Revert Run could trash files that existed before the run and treated paths as globs; New Launch
  Film in an init scaffold scanned the Launch package instead of the app; the Comments empty state
  made the window content taller than the window, clipping the sidebar footer and agent panel;
  Settings › Playback values were never read.
- LaunchKit: title lines rendered at different sizes, feature details and terminal lines were
  truncated, the terminal session was cut off at the shot end, the stage was empty for 9–15 frames
  after each cut, the hero hits drifted at 90/120 BPM, a symlinked root or a capped scan hid the
  README, and corrupt icon metadata or out-of-root icon paths were trusted.

## 0.9.0 — 2026-10-06

### Added
- **`render --jobs n|auto`** — parallel rendering across processes, stitched by the new
  `MP4Assembler` without re-encoding; frame-exact against a single-process render
  (StyleLab 41 s 1080p60: 65 s → 19 s at 5 jobs).
- **`VisionTrack`** — Apple Vision body pose, hand pose and person masks per frame, analyzed
  once and cached; `PoseOverlay`; `Rotoscope` demo scene (PropsScene: clip + Stylize look).
- **`swift-render smoke`** — one frame of every scene plus a no-swish check; runs in CI.
- **`check` voice vs music** — dB the voiceover sits above the ducked music while speaking,
  with buried time spans.
- `Bundle.swiftRender`, `ShaderLibrary.swiftRender`, public `PostFX.init`.
- `NeverHeard` — a 93 s first-person short narrated with local TTS (Kokoro, `say` fallback).
- `SlipDueLaunch` — 28 s vertical launch spot.
- `Release090` — a 40 s narrated tour of this release.

### Changed
- Demo scenes moved to a separate **`SwiftRenderScenes`** target/product — the library no
  longer compiles them. The registry plugin scans both targets.
- Voiceover has its own mixer bus; kicks/booms/samples now duck ~4.5 dB under speech.
- The recorder's audio mux copies the video stream (was a full re-encode); encoder writes no
  B-frames so frame 0 sits at t=0.
- `whoosh` / `riser` are deprecated and removed from every scene. Rebalanced voice levels in
  SlipDueLaunch (voice was 5.8 dB under the music), MediaDemo and NeverHeard.

### Removed
- JETRAY scenes and their assets (`assets/seeker`, `assets/plate`, `data/`) — 64 MB.

### Fixed
- `--range` passed the range end as the scene's duration (wrong fades/timing) and gave
  audio-reactive scenes silence; frame times now come from absolute frame indices.
- Shader count corrected to 22 everywhere (README said 12, Sizzle and the quickstart said 23).


## 0.8.1 — 2026-10-02

### Added
- **Transition marks** — clean, noise-free alternatives to swish transitions:
  `tick(at:)` (woodblock click), `rim(at:)` (mid knock), `thump(at:)` (soft low hit),
  `blip(note, at:)` (pure sine), `swell(note, at:, duration:)` and
  `swell(chord, into: t, duration:)` (a pitched build that stops on the downbeat).
- `check` warns when a score uses noise sweeps (`whoosh`/`riser`).

### Changed
- **House rule: no swish transitions.** `StyleLab` drops its per-cut whooshes and replaces its
  risers with chord swells. `whoosh`/`riser` remain in the API for existing scenes, but new
  scenes should mark cuts with the music or the transition marks above.

## 0.8.0 — 2026-10-02

### Added
- **Samples in the Score** — `sample(path, at:, amp:, pan:, rate:, offset:, duration:)` plays any
  wav/aiff/caf/m4a/mp3 or the audio track of an mp4/mov. Decoded once to 44.1 kHz stereo and
  cached; routed around the kick duck. `samples(path, at: [t])` for anchors.
- **Voiceover** — `speak("…", at: t, engine: .say(voice:wpm:) | .kokoro(voice:))`. Lines are
  synthesized locally on first use and cached by content hash (`~/Library/Caches/swift-render/tts`),
  so renders stay deterministic. The music bus ducks ~6 dB under speech.
- **Captions** — `CaptionTrack(score)` builds timed cues from the `speak` lines (voiced span of
  the rendered audio, word timing by length + punctuation, balanced line splits);
  `CaptionView(track, at: t)` burns them in with a karaoke highlight;
  `swift-render captions <Scene> --out x.srt|.vtt` exports a sidecar.
- **Video & image clips** — `VideoClip(path, at:, rate:, offset:, loop:, contentMode:)` with
  zero-tolerance frame decode; `ImageClip(path)`; `MediaLibrary` for raw frames/durations;
  `AssetPaths` resolves scene paths (cwd, assets/, package root).
- **`swift-render preview <Scene>`** — live window: scrubber, play/pause (space), frame-step (←/→,
  ⇧ for 1 s), timecode/frame readout, synced audio. `--snapshot out.png` captures the window and exits.
- `crackle(from:to:)` vinyl bed voice; `ScoreSynth.render(_:normalize:)` for un-normalized stems.
- `RenderFrame` — the one frame wrapper (size, render context, PostFX) shared by recorder,
  PNG frames and preview.
- `check` reports samples (and missing files) and voiceover (lines, seconds, caption cues).
- `scripts/typecheck-budget.sh` + CI step — flags expressions/functions slow to type-check
  before CI's older compiler rejects them.
- `MediaDemo` scene; `assets/demo/clip.mp4`; tests for samples, captions, voiceover, video frames.

### Changed
- `OpenEarLaunch` carries its foley in its own Score (`assets/openear-foley`) —
  `tools/openear_launch_mix.py` is gone; `check` now reports the real mix.
- Split the four slowest type-check spots (Kinetic, KineticType, LaunchFilm).

## 0.7.0 — 2026-10-02

- `PixelGrid` (sample any view to an RGBA grid) and `Stylize` — 16 deterministic whole-frame
  renderers (pixel, dither, gameBoy, ascii, halftone, cmyk, mosaic, led, engraving, crosshatch,
  pointillism, bricks, crossStitch, lowPoly, blueprint, thermal); `StyleLab` demo reel.

## 0.6.0 — 2026-10-02

- Scene registry generated at build time (SceneRegistryPlugin) — no hand-edited dictionary.
- MetalCompilerPlugin falls back to `Shaders/prebuilt.metallib` without the Metal toolchain.
- CLI: `new`, `check`, `frame --at a,b,c`, `render --preview --open`; contact sheets sample shot midpoints.
- `Music.swift` (notes, chords, scales, instruments, phrases); `Dither`, `PixelCanvas`, `PixelFont`.
- PostFX opaque base; CI on macos-15.

## Earlier, between 0.5.0 and 0.6.0

- LaunchFilm2, StyleReel, StyleReelVertical now score themselves in Swift —
  the Python soundtrack sidecars (make_launch/reel/kinetic_audio.py) are gone

- **Sound, in Swift** — `Score` DSL (`soundtrack(duration:)` on every scene
  protocol): kicks/claps/hats/crashes/bass/risers/booms/drones/whooshes with
  pattern helpers (fourOnFloor, hatSixteenths, bassline) and anchor placement
  (`crashes(at: chapters)`) so cuts and hits share one source of truth.
  Deterministic pure-Swift synth (vDSP), two-bus sidechain master, auto-mux —
  `render <Scene>` needs no --audio. `audio <Scene>` exports the WAV.
  In-memory FFT path: audio-reactive scenes react to their own score.

- `RenderContext` environment value — scenes can read render size/fps/duration
  (`@Environment(\.renderContext)`) and adapt layout per aspect

- MetalCompilerPlugin: .metal files now compile automatically at build time —
  checked-in metallib and manual tools/build_shaders.sh step are gone

- StyleReel + StyleReelVertical (9:16) — 12-aesthetic showcase scenes with
  card-zoom transitions + tools/make_reel_audio.py

- `contact <Scene> --cols 5 --rows 3` — labelled grid contact sheet PNG
  (full-size layouts downscaled, last sample lands before the end fade)
- `LaunchFilm` scene (57.5s launch film) + `tools/make_launch_audio.py`
  soundtrack engine (two-bus sidechain) + `tools/mix_vo.py` VO mixer
- Mono.metal studio shader pack: metaballs, inkFlow, interference,
  voronoiInk, monoTunnel (designed palettes)

## 0.5.0 — 2026-06-10

First release cut with the full "beat Remotion" API surface.

### Added
- **Timeline API** — `Timeline(t) { Clip(…) }` result-builder sequencing with
  local-time remapping, pinned overlay clips (`Clip(at:for:)`), and
  cross-transitions (`.cut`, `.fade`, `.slide`, `.flash`, `.overlap`).
- **Analytic springs** — closed-form damped `Spring` (under/critical/overdamped)
  evaluated at any `t`, plus `easeOutBack`, `elastic`, `bounce`, `expo`,
  and CSS-style `cubicBezier`.
- **Audio-reactive scenes** — `--audio` pre-analyzes the file (FFT) into RMS +
  bass/mid/high envelopes; scenes read `audio.band(.bass, at: t)` as pure,
  deterministic lookups. WAV/AIFF/AAC/M4A inputs.
- **JSON props** — `PropsScene`/`PropsAudioScene` protocols,
  `swift-render props <Scene>` template printing, `--props file.json`.
- **CLI** — `frame <Scene> --at <t>` single-PNG export, `render --range a:b`
  partial renders, `--no-postfx`, `--version`; unknown flags now error.
- **Library product** — `import SwiftRender` from your own package; the CLI is
  a thin wrapper. Test suite (determinism, springs, easing, timeline, audio)
  + GitHub Actions CI.
- `tools/build_shaders.sh` + a loud runtime warning when `.metal` sources are
  newer than the bundled `default.metallib`.

### Fixed
- Flickering grain-free strip on frame edges (PostFX tile offset overscan).
- Film-grain noise tile now seeded — frames are byte-identical across runs.
- `PostFX` no longer doubles when a scene applies its own (`ownsPostFX`).
- Kinetic marquee covers the full frame; galaxy shader stars are round points.

### Scenes
- New: `Kinetic`, `JustRenderIt` (+ `tools/make_jri_audio.py` beat track),
  `AudioBars` (audio + props reference), `TimelineDemo` (Timeline reference).
