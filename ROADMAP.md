# swift-render roadmap

*Shipped so far: 0.9 added the `SwiftRenderScenes` demo target, `render --jobs`, frame-exact `--range`, `smoke` CI, and VisionTrack + Rotoscope. 0.10 added Studio, the review loop, the MCP server, LaunchKit and launch films, and Scene3D ([below](#010-studio-preview--shipped)).*

**Goal:** make swift-render the default way Swift teams produce launch films, App Store previews and release videos.
The film is written in SwiftUI and reviewed in a native editor. A specialized agent applies the review notes.

```
   your Swift repo ──► swift-render launch ──► film (MP4, 16:9 + 9:16)
          │                                         │
          ▼                                         ▼
     Launch/ package  ◄── edits ──  director agent ◄── timecoded / region comments ◄── swift-render Studio
     (your scenes)                  (Claude Code + MCP,                              (watch · scrub · tune · comment)
                                     later first-party)
```

Four pillars. Each ships in every release:

| Pillar | What it is | License |
|---|---|---|
| **Engine** | SwiftUI scenes as pure functions of `t`, Timeline, Score, Metal, Recorder, LaunchKit | MIT, forever |
| **Studio** | Native macOS editor: hot reload, timeline lanes, knobs, props, comments, render queue | Core is MIT; Pro features are paid |
| **Review loop** | Git-native comments, `swift-render review`, MCP server, `swift-render-director` agent, Claude Code plugin | MIT |
| **Cloud** | Review links, team sync, GitHub app, hosted Director agent, template marketplace | Paid |

The rule for where the line falls: anything one person can do offline on their own Mac is free and open. Anything that needs our servers, curated content or our hosted agent is paid.

---

## 0.10: Studio preview — shipped

Released as 0.10.0 on 2026-10-15; the full list is in [CHANGELOG.md](CHANGELOG.md#0100--2026-10-15).

- [x] **Packages for any codebase.** The CLI is a library (`SwiftRenderTool`); any package ships its own `swift-render`-style executable. `SceneRegistryPlugin` is exported, `swift-render.json` marks the project, and `SwiftRenderKit` holds the Foundation-only shared model.
- [x] **Engine introspection.** Clips report `file:line`, `.named()` labels and transitions; `Knob.double/bool/text/color`; Score lanes; `swift-render info --json`.
- [x] **swift-render Studio.** Hot reload (≈2 s), timeline lanes, viewer with safe areas and A/B compare, knobs/props/check in the inspector, region and range comments, the agent panel with checkpoints and Revert Run, the render queue with App Store presets, right-click menus with Delete and Undo, `--snapshot` for CI, and a packaged `.app` (`scripts/package-studio.sh`).
- [x] **Studio performance.** Release-built exports with `--jobs auto`, zero-copy IOSurface display, first-frame-first opens, warm scenes and a playback quality ladder.
- [x] **Review loop.** `swift-render review`, the `swift-render-director` agent, the review and make skills, and the Claude Code plugin and marketplace entry.
- [x] **MCP server.** `swift-render-mcp` with 21 tools: creation (launch films, scenes, props), rendering with jobs for long work, the API guide, and the review loop; project, standalone and docs-only modes.
- [x] **LaunchKit and `AppleLaunch`.** Keynote-grammar components; `swift-render launch <repo>` scans a codebase and renders its film; `swift-render init` scaffolds a `Launch/` package you own.
- [x] **3D.** `Scene3D`: deterministic SceneKit inside any scene, with models, PBR materials, SwiftUI textures, lights and depth of field (`Showcase3D`).
- [x] **Parallel export.** `render --jobs` hands out small pieces of the film as processes free up.

**Still open from 0.10:**
- Push the `v0.10.0` tag. Until it exists on the remote, `init` without `--local` (which writes `from: "0.10.0"`) can't resolve the package.
- A real model turn of the review loop: everything up to the model call is verified; run `python3 scripts/mcp-smoke.py --claude` on a machine with a signed-in `claude` CLI.
- Studio gestures (retime drag, region drag, compare wipe, sheets) have been exercised through snapshots and unit tests, not by hand in a visible window.
- Knob values saved from Studio's inspector fail silently when the knob file is unreadable (MCP and the CLI already report it).
- Review `source.file` is stored as an absolute path; make it project-relative so comments survive a checkout move.
- LaunchKit polish: the package CTA chip at 9:16, long product names on the 9:16 end card.

## 0.11: Launch everywhere

- **App Store Preview Kit.**
  - Every required device size, per locale.
  - Enforces the spec: 15–30 s, ≤30 fps, ≤500 MB, H.264 or ProRes 422 HQ.
  - Localized variants through `--props`.
- **Masters.** ProRes 4444 and HEVC with alpha, 10-bit, transparent overlays.
- **LaunchKit styles:** Keynote (default), WWDC "What's new", Changelog / release notes, PR film, and an App Store 30 s cut.
- **Your own SwiftUI in the film.** A documented path to render your app's real SwiftUI views inside `DeviceFrame`: factor them into a package and import it into `Launch/`. A linter flags AppKit- or UIKit-backed views that `ImageRenderer` can't capture.
- **`swift-render doctor --json`.** Checks the toolchain, Metal compiler, TTS voices and ffmpeg. Gives agents an `ok` flag to gate on.
- **Scheduled audio work.** Release-built score synthesis worker (6–20× faster than debug). Onset detection and configurable FFT bands.

## 1.0: Studio

- **Distribution.** Signed and notarized `swift-render Studio.app`, Sparkle updates, Homebrew cask, `swift-render studio` launcher.
- **Templates registry.** `swift-render add <template>` installs `PropsScene` packages with `defaultProps`. First-party packs, then community packs.
- **Stability.** Stable public API: Scene protocols, Timeline, Score, LaunchKit and the host protocol, with semver guarantees.
- **Docs site and gallery.** Launch films for popular Swift packages, made only with their maintainers' consent. Every swift-render release ships its own film.
- **Editing.**
  - "Bake knobs into source" (write tuned values back as literals).
  - New Scene from a template inside Studio.
  - Multi-scene projects.

## 1.1: Review links and teams

- **Review links.** Render locally, upload an H.264 proxy, and share a link. Viewers leave timecoded and region comments in the browser, and the same comments land in `.swift-render/reviews/` for the agent. The browser never runs a scene; it only plays video and draws overlays.
- **swift-render Review** for iOS, iPadOS and macOS. Plays links and posts comments, with no code execution, so it can ship on the App Store.
- **GitHub app.**
  - Comments sync with issues and PR review threads.
  - Renders run as a PR check with before/after.
  - "Film of this PR" bot.
- **Team workspaces.** Version stacks (render N vs N+1), approval states, Slack notifications.

## 1.2: Director, the first-party agent

- **An agent built on the Claude Agent SDK, inside Studio.** No Claude Code install is needed, and bring-your-own Claude Code keeps working. It has specialized tools: render, look, compare, check, edit scene, tune knobs, score.
- **Vision critique loop.** The agent watches its own render, scores it against an Apple launch-film rubric (type, rhythm, hierarchy, sync), and iterates before asking a human.
- **One-shot "launch film from this repo."** Covers script, storyboard, voiceover, score, film and App Store cut.
- **Hosted, on credits.** Hosted runs are billed on usage credits; local runs with your own Claude Code are free.

## 2.0: Beyond

- **Sub-second hot reload** through dylib injection, plus scenes split into their own module so release-mode hosts rebuild fast.
- **Sequence editing.** A real NLE over scenes: trims, ripple, versions, while keeping scenes as code.
- **Real-time collaborative review** in Studio.
- **Batch rendering.** A Mac render fleet for data-driven variants (personalized films, localized App Store previews), billed per output minute.
- **Enterprise.** SSO, brand kits, private template registry, on-prem render nodes.

---

## Principles that don't change

1. **A scene is a pure function of time.** That is what makes renders deterministic, scrubbing free, and code an agent can write correctly.
2. **Native Apple output.** SF type, SF Symbols, Metal, SwiftUI materials, App Store formats. We don't compete with HTML video on reach; we beat it on Apple-native quality.
3. **Git is the source of truth.** Scenes, knobs and review comments are files in your repo. The editor and the agent are both just clients.
4. **The engine stays MIT with no company-size clauses.**
5. **No swish transitions.** Cuts are marked with music.

Have a feature request? Open an issue tagged `roadmap`.
