# Contributing to swift-render

Thanks for thinking about contributing. This doc covers the basics.

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

1. Create `Sources/SwiftRender/Scenes/YourScene.swift` implementing `RenderScene`:
   ```swift
   public struct YourScene: RenderScene {
       public static let defaultDuration: Double = 3.0
       public static func body(at t: Double, duration: Double) -> some View {
           // pure function of t — see Easing.swift for helpers
       }
   }
   ```
2. Register in `Sources/SwiftRender/main.swift`'s `sceneRunners` dict.
3. Build + render. Done.

## Adding a shader

1. Add a `[[ stitchable ]]` function to a `.metal` file in `Sources/SwiftRender/Shaders/`.
2. `swift build` — the MetalCompilerPlugin compiles all shaders into the
   metallib automatically (requires full Xcode for the metal toolchain).
3. Use it in a scene via `ShaderLibrary.bundle(.module).yourShader(...)`.

## Style

- Keep scenes pure functions of `t`. No `@State`, no `Timer`, no `withAnimation(.repeatForever)`.
- Use `Ease.clip(t, start, end)` and the easing helpers for timing.
- Document scene timing in the doc comment (`0.0–1.2s : …`).
- Frame the body method `@MainActor`.
- Public APIs need doc comments.

## Tests

Render-based smoke tests live in `Tests/` (planned — PRs to bootstrap welcome).

## Reporting bugs

Open an issue with:
- Scene name
- Command line you ran
- Expected vs actual (frame extracts via `ffmpeg -ss N -update 1 -frames:v 1` help a lot)
- macOS + Swift version

## Code of conduct

Be decent. Don't be a jerk. Help newcomers.
