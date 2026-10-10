# Contributing to swift-render

Swift Render is a reusable video engine, a CLI, and a separate collection of demo scenes. Keep each change in the layer that owns it.

## Where changes belong

- `Sources/SwiftRender/`: reusable engine APIs, audio, media, Vision, rendering, and components.
- `Sources/SwiftRenderScenes/`: examples and scene-specific logic.
- `Sources/SwiftRenderCLI/`: CLI commands and preview/check/export workflows.
- `Plugins/`: build-time scene registration and Metal compilation.
- `Tests/SwiftRenderTests/`: engine regression tests.
- `docs/`: guides and reviewed demo assets.
- `out/`: generated renders, never source files.

Keep app-specific assets and demo behavior out of the engine when practical. Avoid bundling private source, credentials, or assets without permission.

## Development loop

```bash
# Build
swift build

# Render a scene to verify your changes
swift run swift-render render <YourScene> --out out/test.mp4

# Open the result
open out/test.mp4
```

## Adding a scene

1. Create `Sources/SwiftRenderScenes/YourScene.swift` implementing `RenderScene`:
   ```swift
   public struct YourScene: RenderScene {
       public static let defaultDuration: Double = 3.0
       public static func body(at t: Double, duration: Double) -> some View {
           // pure function of t - see Easing.swift for helpers
       }
   }
   ```
   (or `swift run swift-render new YourScene` to scaffold one with a Timeline + Score).
2. That's it for registration - `SceneRegistryPlugin` finds every `public struct X` that
   conforms to a scene protocol and registers it as `"X"` at build time.
3. `swift run swift-render check YourScene`, review the contact sheet + report, then render.

## Adding a shader

1. Add a `[[ stitchable ]]` function to a `.metal` file in `Sources/SwiftRender/Shaders/`.
2. `swift build` - the MetalCompilerPlugin compiles all shaders into the
   metallib automatically. This needs the Metal compiler
   (`xcodebuild -downloadComponent MetalToolchain`); without it the build falls back
   to `Shaders/prebuilt.metallib` and renders warn that your edit isn't live.
3. After a successful compile, refresh the fallback so toolchain-less machines get it:
   `cp .build/release/SwiftRender_SwiftRender.bundle/default.metallib Sources/SwiftRender/Shaders/prebuilt.metallib`
4. Use it in a scene via `ShaderLibrary.swiftRender.yourShader(...)` (scenes live in another target, so `.module` would be the wrong bundle).

## Style

- Keep scenes pure functions of `t`. No `@State`, no `Timer`, no `withAnimation(.repeatForever)`.
- Use `Ease.clip(t, start, end)` and the easing helpers for timing.
- Document scene timing in the doc comment (`0.0–1.2s : …`).
- Frame the body method `@MainActor`.
- Public APIs need doc comments.

## Tests

Run the existing tests and smoke workflow:

```bash
swift build
swift test
swift run swift-render smoke
```

`Tests/SwiftRenderTests/` covers timelines, easing, springs, audio scoring/analysis, media, components, render context, and determinism. CI builds, tests, and smoke-renders on macOS. Add a regression test for engine changes.

For visual changes, inspect representative frames and the encoded movie. For sound changes, listen to the export as well as reading the audio report. A passing build is not a review of the output.

## Reporting bugs

Open an issue with:
- Scene name
- Command line you ran
- Expected vs actual (frame extracts via `ffmpeg -ss N -update 1 -frames:v 1` help a lot)
- macOS + Swift version

## Code of conduct

Be decent. Don't be a jerk. Help newcomers.
