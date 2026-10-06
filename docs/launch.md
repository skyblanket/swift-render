# Launch films

`swift-render launch` turns a Swift codebase into an Apple-keynote-style launch film:
it scans the repo, writes the facts it found to a JSON file you can edit, and renders the
`AppleLaunch` scene. `swift-render init` gives you the same film as Swift you own.

```bash
swift run swift-render launch ~/Code/MyApp --open              # scan + render → MyApp/out/myapp-launch.mp4
swift run swift-render launch ~/Code/MyApp --aspect 9:16       # vertical cut, same plan
swift run swift-render init ~/Code/MyApp                       # scaffold MyApp/Launch/, a package you edit
```

## `launch`

```
swift-render launch [path=.] [--out f.mp4] [--aspect 16:9|9:16|1:1] [--props-out f.json]
                    [--voiceover] [--preview] [--open] [--eject] [--rescan] [--no-render] [--no-manifest]
```

1. **Scan** (`LaunchScanner`, offline, under a second on most repos). It prints every value
   with the file it came from, plus conflicts (e.g. CHANGELOG says 0.8.1, latest tag is v0.5.0)
   and what it could not find.
2. **Props** go to `<path>/.swift-render/launch/<Name>.json` (the scan evidence next to it in
   `<Name>.scan.json`). On later runs the existing file is reused — it is the thing you, Studio
   and the review agent edit. `--rescan` replaces it.
3. **Render** `AppleLaunch` in-process with those props → `<path>/out/<name>-launch.mp4`.
   `--preview` renders half-size at 30 fps. Props edits need no rebuild.

`--eject` also writes an editable `<Name>Launch.swift` into the project's scenes directory
(`swift-render.json` `scenesDir`, or `Sources/SwiftRender/Scenes` in this repo).
`--no-manifest` skips `swift package dump-package` (which runs the manifest) for untrusted code.

Iterate on the JSON with the usual loop:

```bash
swift-render check AppleLaunch --props .swift-render/launch/MyApp.json    # contact sheet + audio report
swift-render frame AppleLaunch --props .swift-render/launch/MyApp.json --at 5,12,30
```

Run these from the scanned project's root: icon and screenshot paths in the props are relative to it.

## What the scanner reads

| Source | Fields |
|---|---|
| `Package.swift` (`swift package dump-package`, regex fallback) | name, products → kind, platforms + minimums, dependency count, tools version |
| `*.xcodeproj/project.pbxproj` | app target, `PRODUCT_NAME`, `MARKETING_VERSION`, deployment targets, `SWIFT_VERSION`, display name, app icon set name |
| `Assets.xcassets` | `AppIcon` (largest image, light appearance), `AccentColor` (hex) |
| `Info.plist` | `CFBundleDisplayName` / `CFBundleName` |
| `README.md` | title, tagline + subtitle (first lead paragraph), features (bullets under a Features-like heading, else H3s, else H2s), first ```swift block, `.package(url:)` install line, shell commands |
| `CHANGELOG.md` | latest released version, date, up to five items (Added > Performance > Changed > Fixed) |
| `LICENSE` | MIT / Apache-2.0 / BSD / GPL / MPL / ISC |
| git | commits, contributors (bots dropped), first commit date, release tags, GitHub URL from `origin` |
| `*.swift` | lines of Swift, test count (`func test…` + `@Test`), a short SwiftUI view for apps without a README snippet |
| `fastlane/screenshots`, `Screenshots/`, `docs/screenshots` | PNG screenshots, device guessed from pixel size |

Accent precedence: `AccentColor` → the README release badge `color=` → the icon's dominant hue
→ a default. Accents under 3:1 contrast on the stage are lightened. Numbers are never invented:
highlights come from git and file counts, and small ones (3 stars) are dropped.

## Props

Every key is optional; `{"name": "Halo"}` is a valid film. Unknown enum values, wrong types and
malformed list items fall back to defaults instead of failing. `swift-render props AppleLaunch`
prints a complete example. The fields that change the film most:

| Key | Effect |
|---|---|
| `name`, `tagline`, `subtitle` | hero, title shot (tagline split over two lines, second in the accent) |
| `kind` | `app` leads with the device shot, `library`/`framework` with code, `cli` with the terminal |
| `icon` | `{"path": "…", "shape": "iOS" \| "macOS" \| "none"}`; missing → a generated monogram tile |
| `accent`, `accentSecondary`, `appearance`, `typeface` | look; `typeface: "inter"` for license-safe commercial renders |
| `features` | 3–6 `{title, detail, symbol}`; four fit one row, five or six add an "And so much more." shot |
| `screenshots`, `code`, `terminal` | the two "deep" shots (`terminal` lines starting `$ ` are typed) |
| `highlights` | up to three `{value, format: integer\|compact\|percent\|multiplier, label}` count-ups |
| `changelog`, `version` | "What's new in x.y." |
| `platforms`, `swiftVersion`, `facts` | platforms shot; the first fact is its headline ("Zero dependencies.") |
| `cta` | `availableNow`, `downloadForMac`, `appStore`, `swiftPackage`, `github`, `brew`, `custom` |
| `voiceover`, `voiceoverLines` | spoken lines (local TTS) by shot id; generated for hero/title/triad/end |
| `music` | `bpm` 90/100/120, `key` (semitones from D), `mood` calm/bright/driving |
| `shots` | `[{"id": "stats", "hidden": true}, {"id": "triad", "bars": 3}]` |

## The film

`LaunchPlan` turns props into whole bars at a tempo whose beats land on whole 60 fps frames
(100 BPM: 36 frames a beat, 144 a bar). The Timeline and the Score both read it.

| Shot | Bars | Picture | Sound |
|---|---|---|---|
| open | 1 | stage light comes up, "Introducing" | Dmaj7 pad, two bells |
| hero | 2 | icon springs out of a tilt, specular sweep, name focuses in letter by letter | swell into it, `thump`, strum |
| title | 1–2 | tagline headline + subtitle | `rim`; soft groove enters |
| triad | 2 | three (or four) glass feature cards, one per beat | `rim` per card |
| more | 2 | features 4–6 beside "And so much more." | `rim` per row |
| device / code / terminal | 2 each | screenshot in a device, highlighted Swift cascading in, a typed shell session | `thump` / `tick` per line / `tick` per keystroke |
| stats | 2 | up to three count-ups | `blip` on each landing, chord tones |
| changelog | 2 | "What's new in x.y." rows | `rim` per row |
| platforms | 1 | fact headline, platform badges | drums out, swell into the end |
| end | 3 | focus-pull into icon, name, "Available now.", CTA, URL, footnote | `thump`, strum, bell melody |

House rules held by the defaults: one accent; SF Pro display type tracked −2.5% at hero sizes;
springs damped 0.72–0.82; a slow 4.5% push on every shot; hard cuts on downbeats and a single
dissolve (into the end card); grain 0.035, vignette 0.25; no camera shake, no flash frames, no
whoosh/riser/crash in the score. Every layout restacks for 9:16.

## LaunchKit

The scene is built from public components in `Sources/SwiftRender/LaunchKit/`, each a pure
function of a local time `t`, themed by `.launchTheme(_:)` and sized from `\.renderContext`:

- `LaunchTheme`, `Motion` (`pop`, `rise`, `typed`, `beatPulse`, `push`, `hash`), `.reveal(_:)`,
  `.specularSweep(at:start:)`, `.launchPostFX(at:)`, `Transition.focusPull`, `Transition.zoomThrough`
- `Stage`, `Eyebrow`, `KeynoteTitle` (`.rise`, `.letters`, `.words` reveals)
- `LaunchIcon`, `AppIconHero`, `GlassPanel`, `DeviceFrame(.iPhone | .iPad | .mac | .macWindow)`, `ScreenshotView`
- `FeatureCard`, `FeatureTriad`, `FeatureList`
- `SwiftHighlighter`, `CodePalette`, `CodeReveal` (`.lines`, `.typed`, `.instant`; focus lines), `TerminalCard`
- `StatCounter`, `StatRow`, `ChangelogList`, `PlatformBadges`, `EndCard`
- `LaunchScore` (the soundtrack, with `Cue` timings shared with the picture), `AppleLaunchShot` (any stock shot)

Components that make a sound expose their timing (`FeatureTriad.landTimes`, `CodeReveal.lineTimes`,
`TerminalCard.keystrokeTimes`, `StatRow.landTimes`, `ChangelogList.rowTimes`) so a score can hit
the exact frames the picture uses.

**Glass.** `.ultraThinMaterial` does render under `ImageRenderer` on macOS 26, but it follows the
host's transparency settings, so `GlassPanel` defaults to a tinted fill with a lit hairline
(identical on every machine). Pass `backdrop:` to blur an explicit view, or `material: true`.

**Type licensing.** SF Pro's license is written for UI mock-ups; for paid marketing renders use
`"typeface": "inter"` (SIL OFL, bundled).

## `init`

```
swift-render init [path=.] [--local <swift-render checkout>] [--force]
```

Scaffolds `<path>/Launch/`:

```
Launch/
  Package.swift                     depends on swift-render (from: "0.10.0", or a path with --local)
  Sources/LaunchScenes/<App>Launch.swift   your film: LaunchKit + the scanned props as Swift defaults
  Sources/launch/main.swift         await SwiftRenderCommand.main(scenes: generatedSceneRunners)
  swift-render.json                 {"product": "launch", "scenesDir": "Sources/LaunchScenes"}
  .mcp.json                         the swift-render MCP server, for the review loop
  assets/                           the icon and screenshots, copied
  README.md
```

```bash
cd Launch
swift run launch list
swift run launch check HaloLaunch
swift run launch render HaloLaunch --preview --open
```

The scaffolded scene overrides the title shot as an example and uses `AppleLaunchShot` for the
rest; add a `case` to replace any shot. The executable's module is `LaunchCLI` (product `launch`):
a module named `launch` would shadow a Darwin SDK module that Foundation imports.
