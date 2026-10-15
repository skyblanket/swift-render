import AppKit
import SwiftUI

/// Whole-frame ordered (Bayer 8×8) dither to a small palette — CPU, deterministic,
/// no Metal toolchain needed. Author the scene in grayscale tones; `Dither.render`
/// renders it at 1/`cell` resolution, maps luminance onto the palette ramp with a
/// Bayer threshold, and upscales nearest-neighbour so each dither dot is `cell` px.
///
///     Dither.render(myFrame, size: CGSize(width: 1920, height: 1080), cell: 3,
///                   palette: [.charcoal, .cream])                    // 1-bit noir
///     Dither.render(myFrame, size: …, palette: Dither.gameBoy)     // 4-tone ramp
///
/// The palette is ordered dark → light. Scenes using this should set
/// `ownsPostFX = true` (film grain on top of a dither reads as noise).
public enum Dither {
    /// 8×8 Bayer threshold matrix, row-major, values in 0…1.
    public static let bayer8: [Float] = (0..<64).map { i in
        let x = i % 8, y = i / 8, xc = x ^ y
        let v = ((y & 1) << 5) | ((xc & 1) << 4) | ((y & 2) << 2) | ((xc & 2) << 1)
            | ((y & 4) >> 1) | ((xc & 4) >> 2)
        return (Float(v) + 0.5) / 64
    }

    /// Two-tone charcoal and cream palette.
    public static let noir: [Color] = [Color(red: 0.10, green: 0.10, blue: 0.11), Color(red: 0.94, green: 0.90, blue: 0.80)]
    /// Four-tone green Game Boy palette, dark to light.
    public static let gameBoy: [Color] = [
        Color(red: 0.06, green: 0.22, blue: 0.06), Color(red: 0.19, green: 0.38, blue: 0.19),
        Color(red: 0.55, green: 0.67, blue: 0.06), Color(red: 0.61, green: 0.74, blue: 0.06),
    ]

    /// Renders `content` at `size`, dithers it to `palette` with `cell`-pixel dots and returns the result; black if rendering fails.
    @MainActor
    public static func render<V: View>(_ content: V, size: CGSize, cell: Int = 3, palette: [Color] = noir,
                                       contrast: Float = 1.0, bias: Float = 0.0) -> AnyView {
        let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height))
        renderer.scale = 1.0 / Double(max(1, cell))
        guard let cg = renderer.cgImage, let out = apply(cg, palette: palette, contrast: contrast, bias: bias)
        else { return AnyView(Color.black.frame(width: size.width, height: size.height)) }
        return AnyView(Image(decorative: out, scale: 1).interpolation(.none).resizable()
            .frame(width: size.width, height: size.height))
    }

    /// Dither a CGImage in place of its own resolution (one dot per pixel).
    public static func apply(_ cg: CGImage, palette: [Color], contrast: Float = 1.0, bias: Float = 0.0) -> CGImage? {
        let rgb: [(UInt8, UInt8, UInt8)] = palette.map { c in
            let ns = NSColor(c).usingColorSpace(.deviceRGB) ?? .black
            return (UInt8(ns.redComponent * 255), UInt8(ns.greenComponent * 255), UInt8(ns.blueComponent * 255))
        }
        guard rgb.count >= 2 else { return nil }
        let w = cg.width, h = cg.height
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let steps = Float(rgb.count - 1)
        var result: CGImage?
        px.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) -> Void in
            guard let base = buf.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space, bitmapInfo: info) else { return }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            quantize(base.assumingMemoryBound(to: UInt8.self), w: w, h: h, rgb: rgb, steps: steps,
                     contrast: contrast, bias: bias)
            result = ctx.makeImage()
        }
        return result
    }

    private static func quantize(_ p: UnsafeMutablePointer<UInt8>, w: Int, h: Int,
                                 rgb: [(UInt8, UInt8, UInt8)], steps: Float, contrast: Float, bias: Float) {
        let top: Int = rgb.count - 2
        for y in 0..<h {
            for x in 0..<w {
                let i: Int = (y * w + x) * 4
                let r: Float = Float(p[i]), g: Float = Float(p[i + 1]), b: Float = Float(p[i + 2])
                let lum: Float = (0.299 * r + 0.587 * g + 0.114 * b) / 255
                let shaped: Float = (lum - 0.5) * contrast + 0.5 + bias
                let v: Float = min(1, max(0, shaped)) * steps
                let lo: Int = min(Int(v), top)
                let threshold: Float = bayer8[(y & 7) * 8 + (x & 7)]
                let c = (v - Float(lo)) > threshold ? rgb[lo + 1] : rgb[lo]
                p[i] = c.0; p[i + 1] = c.1; p[i + 2] = c.2; p[i + 3] = 255
            }
        }
    }
}
