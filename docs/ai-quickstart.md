# AI Quickstart

For agents and LLMs working with swift-render. Designed to fit in a small context window.

## Mental model

A **Scene** is a pure SwiftUI function of time. Given `t: Double` (seconds since the scene started) and `duration: Double` (the scene's total length), it returns a `View`. The Recorder calls this function once per frame and encodes the result to MP4.

```swift
public protocol RenderScene {
    associatedtype Body: View
    static var defaultDuration: Double { get }
    @MainActor static func body(at t: Double, duration: Double) -> Body
}
```

Three rules:

1. **No `@State`, no `Timer`, no `withAnimation(.repeatForever)`.** Animation comes from `t`, period.
2. **Use `Ease.clip(t, start, end)` for timing windows.** It returns a 0..1 progress.
3. **Wrap easing.** `Ease.easeOut(Ease.clip(t, 0.5, 1.0))` is the standard pattern.

## Minimal scene template

```swift
import SwiftUI

public struct ExampleScene: RenderScene {
    public static let defaultDuration: Double = 3.0

    public static func body(at t: Double, duration: Double) -> some View {
        // entry: 0.0–0.6s fade-in
        let entry = Ease.easeOut(Ease.clip(t, 0.0, 0.6))
        // exit: last 0.4s fade-out
        let exit = Ease.easeIn(Ease.clip(t, duration - 0.4, duration))
        let visibility = entry * (1.0 - exit)

        return ZStack {
            Color.black.ignoresSafeArea()
            Text("hello")
                .font(.system(size: 96, weight: .semibold))
                .foregroundStyle(.white)
                .opacity(visibility)
                .scaleEffect(0.94 + 0.06 * CGFloat(visibility))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

## Easing reference

```swift
Ease.clip(_ t: Double, _ start: Double, _ end: Double) -> Double  // 0..1 progress in window
Ease.easeOut(_ x: Double) -> Double         // cubic ease-out
Ease.easeIn(_ x: Double) -> Double          // cubic ease-in
Ease.easeInOut(_ x: Double) -> Double       // cubic ease-in-out
```

## Multi-phase timing pattern

For scenes with multiple beats, declare timing windows up top:

```swift
let intro = Ease.easeOut(Ease.clip(t, 0.0, 0.8))
let pulse = Ease.easeInOut(Ease.clip(t, 0.8, 2.0))
let outro = Ease.easeIn(Ease.clip(t, 2.0, 3.0))
```

## Letter-by-letter / staggered reveal

```swift
HStack(spacing: 2) {
    ForEach(Array("HELLO".enumerated()), id: \.offset) { idx, ch in
        let lStart = 0.2 + Double(idx) * 0.05      // 50ms stagger
        let p = Ease.easeOut(Ease.clip(t, lStart, lStart + 0.45))
        Text(String(ch))
            .opacity(p)
            .offset(y: CGFloat(1 - p) * 14)        // drops in 14pt
    }
}
```

## Using shaders from the Cookbook

```swift
Rectangle()
    .fill(.black)
    .colorEffect(
        ShaderLibrary.bundle(.module).plasmaField(
            .float2(1920, 1080),
            .float(Float(t)),
            .float(1.4)
        )
    )
```

Available shaders: `rimGlow`, `foilHolographic`, `plasmaField`, `chromaticAberration`, `audioBars`, `caustics`. Args documented in `Sources/SwiftRender/Shaders/Cookbook.metal`.

## Writing a new shader

Append to `Cookbook.metal`:

```metal
[[ stitchable ]]
half4 yourShader(
    float2 position,        // pixel position
    half4 currentColor,     // view's current pixel color
    float2 size,            // view's pixel size
    float someParam         // your custom args
) {
    float2 uv = position / size;
    // your math here
    return half4(half3(0.5, 0.2, 0.8), 1.0h);
}
```

Then recompile the metallib (see CONTRIBUTING.md).

## Common pitfalls

- **Don't use `@State` in the View** — it won't persist across the per-frame fresh view construction.
- **Don't use `Date()`** — frame deterministic means `t` is the only time source.
- **Don't use `TimelineView`** — its time source isn't synchronized with the Recorder. Just use `t`.
- **`withAnimation { ... }` does nothing useful** — animations interpolate state across renders, but each frame is a fresh render.
- **Text rendering** — use system font with explicit size. SF Pro is default.
- **Background** — always `.frame(maxWidth: .infinity, maxHeight: .infinity)` and a background Color for full-frame scenes.

## CLI reference

```bash
swift run swift-render render <Scene>          # render with defaults
  --duration <s>          # override default duration
  --fps <n>               # default 60
  --aspect 16:9|9:16|1:1  # default 16:9
  --out <path>            # default out/render.mp4
  --audio <path>          # mux audio into output

swift run swift-render list                    # show registered scenes
```

## What an agent should produce when asked to "make a scene"

1. A single `.swift` file containing the scene struct
2. The exact `sceneRunners` entry to add to `main.swift`
3. The CLI command to render it

Nothing else needed. The Recorder, PostFX, font registration, and encoding are all handled.
