import SwiftUI
import AppKit

/// Global post-effects layer applied over every rendered frame.
/// Soft vignette + cheap shader-tiled film grain. Makes everything feel
/// cinema-grade vs plain SwiftUI.
public struct PostFX: ViewModifier {
    var time: Double
    var grainAmount: Double = 0.10
    var vignetteAmount: Double = 0.40
    var enabled: Bool = true

    public func body(content: Content) -> some View {
        ZStack {
            content

            if enabled {
                vignetteAndGrain
            }
        }
    }

    @ViewBuilder private var vignetteAndGrain: some View {
        Group {
            // Vignette
            RadialGradient(
                colors: [.clear, Color.black.opacity(vignetteAmount)],
                center: .center,
                startRadius: 600,
                endRadius: 1300
            )
            .allowsHitTesting(false)
            .blendMode(.multiply)
            .ignoresSafeArea()

            // Grain — single pre-rendered noise image tiled across the frame
            // and offset per-frame so it shimmers without generating 500k+
            // canvas fills each render.
            GrainTile(time: time, amount: grainAmount)
                .allowsHitTesting(false)
                .blendMode(.overlay)
                .ignoresSafeArea()
        }
    }
}

private struct GrainTile: View {
    var time: Double
    var amount: Double

    var body: some View {
        let img = GrainTile.noiseImage
        let frame = floor(time * 24.0)  // 24Hz grain shimmer
        // Per-frame deterministic offset for the tile
        let dx = (sin(frame * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1.0) * 64
        let dy = (sin(frame * 78.233 + 11.0) * 43758.5453).truncatingRemainder(dividingBy: 1.0) * 64

        Image(nsImage: img)
            .resizable(resizingMode: .tile)
            .padding(-80)  // overscan: the per-frame offset below must never expose a bare edge strip
            .opacity(amount * 1.4)
            .offset(x: dx, y: dy)
    }

    /// Static 256×256 grayscale-noise tile. Generated once per process.
    static let noiseImage: NSImage = makeNoiseTile(size: 256)

    private static func makeNoiseTile(size: Int) -> NSImage {
        let bytesPerPixel = 4
        let bytesPerRow = size * bytesPerPixel
        var data = [UInt8](repeating: 0, count: size * bytesPerRow)
        var rng: UInt64 = 0x9E37_79B9_7F4A_7C15  // fixed seed — grain must be identical across runs
        for y in 0..<size {
            for x in 0..<size {
                let i = y * bytesPerRow + x * bytesPerPixel
                rng = rng &* 6364136223846793005 &+ 1442695040888963407
                let n = UInt8(truncatingIfNeeded: rng >> 33)
                data[i + 0] = n        // B
                data[i + 1] = n        // G
                data[i + 2] = n        // R
                data[i + 3] = 255      // A
            }
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ctx = data.withUnsafeMutableBytes { buf -> CGContext? in
            CGContext(
                data: buf.baseAddress, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: cs, bitmapInfo: info
            )
        }
        guard let cg = ctx?.makeImage() else {
            return NSImage(size: NSSize(width: size, height: size))
        }
        return NSImage(cgImage: cg, size: NSSize(width: size, height: size))
    }
}
