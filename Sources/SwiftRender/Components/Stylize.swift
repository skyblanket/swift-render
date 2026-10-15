import AppKit
import SwiftUI

// MARK: - PixelGrid

/// A small RGBA snapshot of a view — the input every `Stylize` renderer reads.
///
///     let grid = PixelGrid.sample(myView, size: CGSize(width: 1920, height: 1080), cols: 320)
///     Stylize.view(.ascii, grid: grid, size: size)
///
/// Row 0 is the top row. Channels are 0…1 through the accessors.
public struct PixelGrid: Sendable {
    /// Width in pixels.
    public let cols: Int
    /// Height in pixels.
    public let rows: Int
    /// RGBA bytes, row-major, 4 per pixel.
    public var data: [UInt8]

    /// Wraps existing RGBA bytes (`cols × rows × 4`).
    public init(cols: Int, rows: Int, data: [UInt8]) {
        self.cols = cols; self.rows = rows; self.data = data
    }

    static let space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// Copies `cg` into an sRGB RGBA grid at its own resolution; nil if drawing fails.
    public init?(_ cg: CGImage) {
        let w: Int = cg.width, h: Int = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = px.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: PixelGrid.space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        self.init(cols: w, rows: h, data: px)
    }

    /// Render `content` (laid out at `size`) down to a grid `cols` wide.
    @MainActor
    public static func sample<V: View>(_ content: V, size: CGSize, cols: Int) -> PixelGrid? {
        let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height))
        renderer.scale = CGFloat(cols) / size.width
        guard let cg = renderer.cgImage else { return nil }
        return PixelGrid(cg)
    }

    /// RGB at (x, y), 0…1, with coordinates clamped to the grid.
    public func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
        let xx: Int = min(cols - 1, max(0, x)), yy: Int = min(rows - 1, max(0, y))
        let i: Int = (yy * cols + xx) * 4
        return (Double(data[i]) / 255, Double(data[i + 1]) / 255, Double(data[i + 2]) / 255)
    }

    /// Luma (Rec. 601 weights) at (x, y), 0…1.
    public func lum(_ x: Int, _ y: Int) -> Double {
        let c = rgb(x, y)
        return 0.299 * c.0 + 0.587 * c.1 + 0.114 * c.2
    }

    /// Nearest sample at normalized coordinates (0…1).
    public func rgbAt(u: Double, v: Double) -> (Double, Double, Double) {
        rgb(Int(u * Double(cols)), Int(v * Double(rows)))
    }

    /// Luma of the nearest sample at normalized coordinates (0…1).
    public func lumAt(u: Double, v: Double) -> Double {
        lum(Int(u * Double(cols)), Int(v * Double(rows)))
    }

    /// Box-filtered resize (nearest when upsampling).
    public func resized(cols nc: Int, rows nr: Int) -> PixelGrid {
        if nc == cols && nr == rows { return self }
        var out = [UInt8](repeating: 255, count: nc * nr * 4)
        for j in 0..<nr {
            let y0: Int = j * rows / nr
            let y1: Int = min(rows, max(y0 + 1, (j + 1) * rows / nr))
            for i in 0..<nc {
                let x0: Int = i * cols / nc
                let x1: Int = min(cols, max(x0 + 1, (i + 1) * cols / nc))
                var r = 0, g = 0, b = 0, n = 0
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let k: Int = (y * cols + x) * 4
                        r += Int(data[k]); g += Int(data[k + 1]); b += Int(data[k + 2]); n += 1
                    }
                }
                let o: Int = (j * nc + i) * 4
                let d: Int = max(1, n)
                out[o] = UInt8(r / d); out[o + 1] = UInt8(g / d); out[o + 2] = UInt8(b / d)
            }
        }
        return PixelGrid(cols: nc, rows: nr, data: out)
    }

    /// Same width:height as `size`, `cols` wide.
    public func resized(cols nc: Int, fitting size: CGSize) -> PixelGrid {
        let nr: Int = max(1, Int((Double(nc) * Double(size.height) / Double(size.width)).rounded()))
        return resized(cols: nc, rows: nr)
    }

    /// Per-pixel colour map: `(r, g, b, x, y) -> (r, g, b)`, all 0…1.
    public func mapped(_ f: (Double, Double, Double, Int, Int) -> (Double, Double, Double)) -> PixelGrid {
        var out = data
        for y in 0..<rows {
            for x in 0..<cols {
                let i: Int = (y * cols + x) * 4
                let c = f(Double(data[i]) / 255, Double(data[i + 1]) / 255, Double(data[i + 2]) / 255, x, y)
                out[i] = UInt8(min(255, max(0, c.0 * 255)))
                out[i + 1] = UInt8(min(255, max(0, c.1 * 255)))
                out[i + 2] = UInt8(min(255, max(0, c.2 * 255)))
                out[i + 3] = 255
            }
        }
        return PixelGrid(cols: cols, rows: rows, data: out)
    }

    /// The grid as an opaque sRGB `CGImage`.
    public func cgImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        return CGImage(width: cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cols * 4,
                       space: PixelGrid.space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

// MARK: - Stylize

/// Sixteen ways to re-render a frame. Every renderer is a pure function of a
/// `PixelGrid` (plus `t` for the few that drift), drawn into a SwiftUI `Canvas` —
/// CPU-side, deterministic, no Metal toolchain needed.
///
///     let grid = PixelGrid.sample(scene, size: size, cols: 320)!
///     Stylize.view(.halftone, grid: grid, size: size)
///     Stylize.view(.ascii, grid: grid, size: tileSize, density: 0.5)   // fewer, same-size-on-screen cells
public enum Stylize {
    /// The available renderers.
    public enum Style: Int, CaseIterable, Sendable {
        case pixel, dither, gameBoy, ascii, halftone, cmyk, mosaic, led
        case engraving, crosshatch, pointillism, bricks, crossStitch, lowPoly, blueprint, thermal
    }

    /// A Canvas of `size` drawing `grid` in `style`; `density` scales cell counts, `t` drives the styles that drift.
    @MainActor
    public static func view(_ style: Style, grid: PixelGrid, size: CGSize,
                            density: Double = 1, t: Double = 0) -> some View {
        Canvas { ctx, sz in draw(style, ctx, sz, grid, k: density, t: t) }
            .frame(width: size.width, height: size.height)
    }

    /// Draw `style` into `ctx` filling `size`. `k` scales cell counts (0.5 for a quarter-area tile).
    public static func draw(_ style: Style, _ ctx: GraphicsContext, _ size: CGSize, _ g: PixelGrid,
                            k: Double = 1, t: Double = 0) {
        switch style {
        case .pixel:       pixel(ctx, size, g, k)
        case .dither:      dither(ctx, size, g, k)
        case .gameBoy:     gameBoy(ctx, size, g, k)
        case .ascii:       ascii(ctx, size, g, k)
        case .halftone:    halftone(ctx, size, g, k)
        case .cmyk:        cmyk(ctx, size, g, k)
        case .mosaic:      mosaic(ctx, size, g, k)
        case .led:         led(ctx, size, g, k)
        case .engraving:   engraving(ctx, size, g, k)
        case .crosshatch:  crosshatch(ctx, size, g, k)
        case .pointillism: pointillism(ctx, size, g, k)
        case .bricks:      bricks(ctx, size, g, k)
        case .crossStitch: crossStitch(ctx, size, g, k)
        case .lowPoly:     lowPoly(ctx, size, g, k, t)
        case .blueprint:   blueprint(ctx, size, g, k)
        case .thermal:     thermal(ctx, size, g, k)
        }
    }

    // MARK: helpers

    typealias RGB = (Double, Double, Double)

    static func h(_ n: Int) -> Double {
        let x: Double = sin(Double(n) * 12.9898 + 78.233) * 43758.5453
        return x - floor(x)
    }

    static func col(_ c: RGB, _ a: Double = 1) -> Color {
        Color(red: min(1, max(0, c.0)), green: min(1, max(0, c.1)), blue: min(1, max(0, c.2))).opacity(a)
    }

    static func bytes(_ list: [(Double, Double, Double)]) -> [RGB] {
        list.map { ($0.0 / 255, $0.1 / 255, $0.2 / 255) }
    }

    static func nearest(_ pal: [RGB], _ r: Double, _ g: Double, _ b: Double) -> RGB {
        var best: RGB = pal[0]
        var bd: Double = .greatestFiniteMagnitude
        for c in pal {
            let dr: Double = c.0 - r, dg: Double = c.1 - g, db: Double = c.2 - b
            let d: Double = dr * dr * 0.30 + dg * dg * 0.59 + db * db * 0.11
            if d < bd { bd = d; best = c }
        }
        return best
    }

    static func bayer(_ x: Int, _ y: Int) -> Double { Double(Dither.bayer8[(y & 7) * 8 + (x & 7)]) }

    static func fill(_ ctx: GraphicsContext, _ size: CGSize, _ c: Color) {
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(c))
    }

    static func image(_ ctx: GraphicsContext, _ g: PixelGrid, _ size: CGSize, smooth: Bool) {
        guard let cg = g.cgImage() else { return }
        let img = Image(decorative: cg, scale: 1).interpolation(smooth ? .high : .none)
        ctx.draw(img, in: CGRect(origin: .zero, size: size))
    }

    /// Visit every point of a rotated square lattice that falls inside `size`.
    static func lattice(_ size: CGSize, pitch: Double, angle: Double, _ body: (Double, Double) -> Void) {
        let W = Double(size.width), H = Double(size.height)
        let reach: Int = Int((hypot(W, H) / 2 / pitch).rounded(.up)) + 1
        let ca: Double = cos(angle), sa: Double = sin(angle)
        for j in -reach...reach {
            let py: Double = Double(j) * pitch
            for i in -reach...reach {
                let px: Double = Double(i) * pitch
                let x: Double = W / 2 + px * ca - py * sa
                let y: Double = H / 2 + px * sa + py * ca
                if x < -pitch || x > W + pitch || y < -pitch || y > H + pitch { continue }
                body(x, y)
            }
        }
    }

    static func circle(_ x: Double, _ y: Double, _ r: Double) -> CGRect {
        CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
    }

    // MARK: 01 pixel art — 16-colour palette, ordered dither between neighbours

    static let pico8: [RGB] = bytes([
        (0, 0, 0), (29, 43, 83), (126, 37, 83), (0, 135, 81), (171, 82, 54), (95, 87, 79),
        (194, 195, 199), (255, 241, 232), (255, 0, 77), (255, 163, 0), (255, 236, 39),
        (0, 228, 54), (41, 173, 255), (131, 118, 156), (255, 119, 168), (255, 204, 170),
    ])

    static let checker: [Double] = [0, 0.5, 0.75, 0.25]

    static func pixel(_ ctx: GraphicsContext, _ size: CGSize, _ g: PixelGrid, _ k: Double) {
        let s = g.resized(cols: max(8, Int(96 * k)), fitting: size)
        let out = s.mapped { r, gg, b, x, y in
            let d: Double = (checker[(y & 1) * 2 + (x & 1)] - 0.375) * 0.13
            return nearest(pico8, r + d, gg + d, b + d)
        }
        image(ctx, out, size, smooth: false)
    }

    // MARK: 02 one-bit dither

    static func dither(_ ctx: GraphicsContext, _ size: CGSize, _ g: PixelGrid, _ k: Double) {
        let s = g.resized(cols: max(16, Int(320 * k)), fitting: size)
        let dark: RGB = (0.10, 0.10, 0.11), light: RGB = (0.94, 0.90, 0.80)
        let out = s.mapped { r, gg, b, x, y in
            let lum: Double = 0.299 * r + 0.587 * gg + 0.114 * b
            let v: Double = pow(lum, 0.62) * 1.08
            return v > bayer(x, y) ? light : dark
        }
        image(ctx, out, size, smooth: false)
    }

    // MARK: 03 game boy — four greens

    static let dmg: [RGB] = bytes([(15, 56, 15), (48, 98, 48), (139, 172, 15), (155, 188, 15)])

    static func gameBoy(_ ctx: GraphicsContext, _ size: CGSize, _ g: PixelGrid, _ k: Double) {
        let s = g.resized(cols: max(16, Int(160 * k)), fitting: size)
        let out = s.mapped { r, gg, b, x, y in
            let lum: Double = 0.299 * r + 0.587 * gg + 0.114 * b
            let v: Double = min(0.999, max(0, (lum - 0.5) * 1.2 + 0.56)) * 3
            let lo: Int = min(2, Int(v))
            return (v - Double(lo)) > bayer(x, y) ? dmg[lo + 1] : dmg[lo]
        }
        image(ctx, out, size, smooth: false)
    }

    // MARK: 04 ascii — glyph density carries tone, colour rides on top

    static let ramp: [Character] = Array(" .,:;i1tfLCG08@")

    static func ascii(_ ctx: GraphicsContext, _ size: CGSize, _ g: PixelGrid, _ k: Double) {
        let W = Double(size.width), H = Double(size.height)
        let cols: Int = max(12, Int(120 * k))
        let cw: Double = W / Double(cols)
        let chH: Double = cw * 1.7
        let rows: Int = Int((H / chH).rounded(.up))
        let s = g.resized(cols: cols, rows: rows)
        fill(ctx, size, Color(red: 0.02, green: 0.02, blue: 0.03))
        let font = Font.system(size: chH * 0.92, weight: .bold, design: .monospaced)
        let glyphs = ramp.map { ctx.resolve(Text(String($0)).font(font).foregroundColor(.white)) }
        ctx.drawLayer { l in
            for j in 0..<rows {
                for i in 0..<cols {
                    let tone: Double = pow(s.lum(i, j), 0.72)
                    let idx: Int = min(ramp.count - 1, Int(tone * Double(ramp.count)))
                    if idx == 0 { continue }
                    let at = CGPoint(x: (Double(i) + 0.5) * cw, y: (Double(j) + 0.5) * chH)
                    l.draw(glyphs[idx], at: at, anchor: .center)
                }
            }
            l.blendMode = .sourceAtop
            for j in 0..<rows {
                for i in 0..<cols {
                    let c = s.rgb(i, j)
                    let m: Double = max(0.001, max(c.0, max(c.1, c.2)))
                    let lum: Double = 0.299 * c.0 + 0.587 * c.1 + 0.114 * c.2
                    let gain: Double = (0.62 + 0.38 * lum) / m
                    let cell = CGRect(x: Double(i) * cw, y: Double(j) * chH, width: cw + 0.5, height: chH + 0.5)
                    l.fill(Path(cell), with: .color(col((c.0 * gain, c.1 * gain, c.2 * gain))))
                }
            }
        }
    }

    // MARK: 05 halftone — one ink, 45° dot screen

    static func halftone(_ ctx: GraphicsContext, _ size: CGSize, _ g: PixelGrid, _ k: Double) {
        let W = Double(size.width), H = Double(size.height)
        let cols: Int = max(10, Int(104 * k))
        let pitch: Double = W / Double(cols)
        let s = g.resized(cols: cols, fitting: size)
        fill(ctx, size, Color(red: 0.95, green: 0.92, blue: 0.84))
        var dots = Path()
        lattice(size, pitch: pitch, angle: .pi / 4) { x, y in
            let dark: Double = 1 - min(1, pow(s.lumAt(u: x / W, v: y / H), 0.5) * 1.08)
            let r: Double = pitch * 0.61 * dark.squareRoot()
            if r > 0.6 { dots.addEllipse(in: circle(x, y, r)) }
        }
        ctx.fill(dots, with: .color(Color(red: 0.09, green: 0.08, blue: 0.16)))
    }

    // MARK: 06 CMYK — four screens at four angles, multiplied on paper

    static func cmyk(_ ctx: GraphicsContext, _ size: CGSize, _ g: PixelGrid, _ k: Double) {
        let W = Double(size.width), H = Double(size.height)
        let pitch: Double = W / Double(max(10, Int(112 * k)))
        let s = g.resized(cols: max(16, Int(160 * k)), fitting: size)
        fill(ctx, size, Color(red: 0.97, green: 0.95, blue: 0.90))
        let inks: [(Int, Double, RGB)] = [
            (2, 0, (1.0, 0.90, 0.0)),
            (0, 15 * Double.pi / 180, (0.0, 0.66, 0.93)),
            (1, 75 * Double.pi / 180, (0.92, 0.0, 0.55)),
            (3, 45 * Double.pi / 180, (0.10, 0.09, 0.12)),
        ]
        var c2 = ctx
        c2.blendMode = .multiply
        for (channel, angle, ink) in inks {
            var dots = Path()
            lattice(size, pitch: pitch, angle: angle) { x, y in
                let c = s.rgbAt(u: x / W, v: y / H)
                let key: Double = pow(min(1 - c.0, min(1 - c.1, 1 - c.2)), 1.6) * 0.85
                var amount: Double
                switch channel {
                case 0: amount = (1 - c.0) - key * 0.7
                case 1: amount = (1 - c.1) - key * 0.7
                case 2: amount = (1 - c.2) - key * 0.7
                default: amount = key
                }
                amount = min(1, max(0, amount))
                let r: Double = pitch * 0.62 * amount.squareRoot()
                if r > 0.6 { dots.addEllipse(in: circle(x, y, r)) }
            }
            c2.fill(dots, with: .color(col(ink)))
        }
    }

    // MARK: 07 mosaic — glass tiles and grout

    static func mosaic(_ ctx: GraphicsContext, _ size: CGSize, _ g: PixelGrid, _ k: Double) {
        let W = Double(size.width)
        let cols: Int = max(6, Int(64 * k))
        let s = g.resized(cols: cols, fitting: size)
        let cell: Double = W / Double(cols)
        fill(ctx, size, Color(red: 0.16, green: 0.14, blue: 0.13))
        for j in 0..<s.rows {
            for i in 0..<cols {
                let n: Int = j * 977 + i * 131
                let c = s.rgb(i, j)
                let v: Double = 0.86 + 0.26 * h(n)
                let gap: Double = cell * (0.06 + 0.05 * h(n + 5))
                let x: Double = Double(i) * cell + gap, y: Double = Double(j) * cell + gap
                let w: Double = cell - gap * 2
                let tile = Path(roundedRect: CGRect(x: x, y: y, width: w, height: w), cornerRadius: cell * 0.16)
                ctx.fill(tile, with: .color(col((c.0 * v, c.1 * v, c.2 * v))))
                let glint = Path(roundedRect: CGRect(x: x + w * 0.12, y: y + w * 0.10, width: w * 0.46, height: w * 0.16),
                                 cornerRadius: w * 0.08)
                ctx.fill(glint, with: .color(.white.opacity(0.16)))
            }
        }
    }

    // MARK: 08 LED wall — diodes with additive glow

    static func led(_ ctx: GraphicsContext, _ size: CGSize, _ g: PixelGrid, _ k: Double) {
        let W = Double(size.width)
        let cols: Int = max(8, Int(96 * k))
        let s = g.resized(cols: cols, fitting: size)
        let cell: Double = W / Double(cols)
        fill(ctx, size, Color(red: 0.015, green: 0.015, blue: 0.02))
        func diodes(_ c: GraphicsContext, _ scale: Double) {
            for j in 0..<s.rows {
                for i in 0..<cols {
                    let p = s.rgb(i, j)
                    let lum: Double = 0.299 * p.0 + 0.587 * p.1 + 0.114 * p.2
                    let m: Double = max(0.001, max(p.0, max(p.1, p.2)))
                    let gain: Double = (0.22 + 0.78 * pow(lum, 0.8)) / m
                    let r: Double = cell * 0.42 * (0.5 + 0.5 * lum.squareRoot()) * scale
                    let at = circle((Double(i) + 0.5) * cell, (Double(j) + 0.5) * cell, r)
                    c.fill(Path(ellipseIn: at), with: .color(col((p.0 * gain, p.1 * gain, p.2 * gain))))
                }
            }
        }
        var glow = ctx
        glow.blendMode = .plusLighter
        glow.drawLayer { l in
            l.addFilter(.blur(radius: cell * 0.5))
            diodes(l, 1.2)
        }
        diodes(ctx, 1)
    }

    // MARK: 09 engraving — swelling wavy lines

    static func engraving(_ ctx: GraphicsContext, _ size: CGSize, _ g: PixelGrid, _ k: Double) {
        let W = Double(size.width), H = Double(size.height)
        let lines: Int = max(8, Int(62 * k))
        let pitch: Double = H / Double(lines)
        let s = g.resized(cols: max(16, Int(240 * k)), fitting: size)
        fill(ctx, size, Color(red: 0.93, green: 0.91, blue: 0.83))
        let step: Double = max(4, W / 280)
        let n: Int = Int(W / step) + 2
        var ink = Path()
        for j in -1...lines {
            var top: [CGPoint] = [], bottom: [CGPoint] = []
            for i in 0..<n {
                let x: Double = Double(i) * step
                let wave: Double = sin(x / W * 11 + Double(j) * 0.5) * pitch * 0.32
                let y: Double = (Double(j) + 0.5) * pitch + wave
                let dark: Double = 1 - min(1, pow(s.lumAt(u: x / W, v: y / H), 0.6) * 1.05)
                let half: Double = max(0.35, pitch * 0.47 * dark)
                top.append(CGPoint(x: x, y: y - half))
                bottom.append(CGPoint(x: x, y: y + half))
            }
            ink.move(to: top[0])
            for p in top.dropFirst() { ink.addLine(to: p) }
            for p in bottom.reversed() { ink.addLine(to: p) }
            ink.closeSubpath()
        }
        ctx.fill(ink, with: .color(Color(red: 0.06, green: 0.20, blue: 0.16)))
    }

    // MARK: 10 crosshatch — five pen layers, one stroke call

    static func crosshatch(_ ctx: GraphicsContext, _ size: CGSize, _ g: PixelGrid, _ k: Double) {
        let W = Double(size.width)
        let cols: Int = max(12, Int(128 * k))
        let s = g.resized(cols: cols, fitting: size)
        let cell: Double = W / Double(cols)
        fill(ctx, size, Color(red: 0.95, green: 0.93, blue: 0.87))
        var pen = Path()
        for j in 0..<s.rows {
            for i in 0..<cols {
                let lum: Double = min(1, pow(s.lum(i, j), 0.5) * 1.1)
                let x: Double = Double(i) * cell, y: Double = Double(j) * cell
                let n: Int = j * 733 + i * 197
                let a: Double = (h(n) - 0.5) * cell * 0.22, b: Double = (h(n + 3) - 0.5) * cell * 0.22
                if lum < 0.82 {
                    pen.move(to: CGPoint(x: x + a, y: y + cell)); pen.addLine(to: CGPoint(x: x + cell, y: y + b))
                }
                if lum < 0.62 {
                    pen.move(to: CGPoint(x: x + b, y: y)); pen.addLine(to: CGPoint(x: x + cell, y: y + cell + a))
                }
                if lum < 0.44 {
                    pen.move(to: CGPoint(x: x, y: y + cell * 0.5 + a)); pen.addLine(to: CGPoint(x: x + cell, y: y + cell * 0.5 + b))
                }
                if lum < 0.28 {
                    pen.move(to: CGPoint(x: x + cell * 0.5 + a, y: y)); pen.addLine(to: CGPoint(x: x + cell * 0.5 + b, y: y + cell))
                }
                if lum < 0.14 {
                    pen.move(to: CGPoint(x: x + cell * 0.5, y: y + cell)); pen.addLine(to: CGPoint(x: x + cell, y: y + cell * 0.5))
                    pen.move(to: CGPoint(x: x, y: y + cell * 0.5)); pen.addLine(to: CGPoint(x: x + cell * 0.5, y: y))
                }
            }
        }
        ctx.stroke(pen, with: .color(Color(red: 0.10, green: 0.11, blue: 0.24)),
                   style: StrokeStyle(lineWidth: max(1, cell * 0.13), lineCap: .round))
    }

    // MARK: 11 pointillism — dabs of pure colour

    static func pointillism(_ ctx: GraphicsContext, _ size: CGSize, _ g: PixelGrid, _ k: Double) {
        let W = Double(size.width)
        image(ctx, g.resized(cols: max(6, Int(40 * k)), fitting: size), size, smooth: true)
        for (pass, base, radius) in [(0, 40.0, 0.78), (1, 90.0, 0.56)] {
            let cols: Int = max(6, Int(base * k))
            let s = g.resized(cols: cols, fitting: size)
            let cell: Double = W / Double(cols)
            let total: Int = cols * s.rows
            for m in 0..<total {
                let n: Int = (m * 7919 + pass * 13) % total
                let i: Int = n % cols, j: Int = n / cols
                let c = s.rgb(i, j)
                let seed: Int = n * 3 + pass * 100_003
                let jx: Double = (h(seed) - 0.5) * cell * 0.9, jy: Double = (h(seed + 1) - 0.5) * cell * 0.9
                let tint: RGB = (c.0 + (h(seed + 2) - 0.5) * 0.22, c.1 + (h(seed + 3) - 0.5) * 0.22,
                                 c.2 + (h(seed + 4) - 0.5) * 0.22)
                let r: Double = cell * radius * (0.8 + 0.4 * h(seed + 5))
                let at = circle((Double(i) + 0.5) * cell + jx, (Double(j) + 0.5) * cell + jy, r)
                ctx.fill(Path(ellipseIn: at), with: .color(col(tint, 0.92)))
            }
        }
    }

    // MARK: 12 bricks — studs, 16 toy colours

    static let toy: [RGB] = bytes([
        (201, 26, 9), (0, 85, 191), (242, 205, 55), (35, 120, 65), (254, 138, 24), (244, 244, 244),
        (27, 42, 52), (228, 205, 158), (10, 52, 99), (228, 173, 200), (187, 233, 11), (54, 174, 191),
        (129, 0, 123), (114, 14, 15), (200, 80, 150), (172, 120, 186),
    ])

    static func bricks(_ ctx: GraphicsContext, _ size: CGSize, _ g: PixelGrid, _ k: Double) {
        let W = Double(size.width)
        let cols: Int = max(6, Int(48 * k))
        let s = g.resized(cols: cols, fitting: size)
        let cell: Double = W / Double(cols)
        let edge: Double = max(1, cell * 0.06)
        fill(ctx, size, .black)
        for j in 0..<s.rows {
            for i in 0..<cols {
                let p = s.rgb(i, j)
                let c: RGB = nearest(toy, p.0, p.1, p.2)
                let x: Double = Double(i) * cell, y: Double = Double(j) * cell
                ctx.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)), with: .color(col(c)))
                ctx.fill(Path(CGRect(x: x, y: y, width: cell, height: edge)), with: .color(.white.opacity(0.22)))
                ctx.fill(Path(CGRect(x: x, y: y, width: edge, height: cell)), with: .color(.white.opacity(0.14)))
                ctx.fill(Path(CGRect(x: x, y: y + cell - edge, width: cell, height: edge)), with: .color(.black.opacity(0.30)))
                ctx.fill(Path(CGRect(x: x + cell - edge, y: y, width: edge, height: cell)), with: .color(.black.opacity(0.22)))
                let cx: Double = x + cell / 2, cy: Double = y + cell / 2, r: Double = cell * 0.29
                ctx.fill(Path(ellipseIn: circle(cx + edge, cy + edge, r)), with: .color(.black.opacity(0.32)))
                ctx.fill(Path(ellipseIn: circle(cx, cy, r)), with: .color(col((c.0 * 1.06 + 0.03, c.1 * 1.06 + 0.03, c.2 * 1.06 + 0.03))))
                ctx.fill(Path(ellipseIn: circle(cx - r * 0.3, cy - r * 0.32, r * 0.42)), with: .color(.white.opacity(0.28)))
            }
        }
    }

    // MARK: 13 cross-stitch — two strokes per cell on aida cloth

    static func crossStitch(_ ctx: GraphicsContext, _ size: CGSize, _ g: PixelGrid, _ k: Double) {
        let W = Double(size.width), H = Double(size.height)
        let cols: Int = max(8, Int(72 * k))
        let s = g.resized(cols: cols, fitting: size)
        let cell: Double = W / Double(cols)
        fill(ctx, size, Color(red: 0.92, green: 0.89, blue: 0.81))
        var weave = Path()
        for i in 0...cols { weave.move(to: CGPoint(x: Double(i) * cell, y: 0)); weave.addLine(to: CGPoint(x: Double(i) * cell, y: H)) }
        for j in 0...s.rows { weave.move(to: CGPoint(x: 0, y: Double(j) * cell)); weave.addLine(to: CGPoint(x: W, y: Double(j) * cell)) }
        ctx.stroke(weave, with: .color(.black.opacity(0.07)), lineWidth: max(1, cell * 0.05))
        let inset: Double = cell * 0.24
        let thread = StrokeStyle(lineWidth: cell * 0.30, lineCap: .round)
        for j in 0..<s.rows {
            for i in 0..<cols {
                let p = s.rgb(i, j)
                let lum: Double = 0.299 * p.0 + 0.587 * p.1 + 0.114 * p.2
                let c: RGB = (lum + (p.0 - lum) * 1.35, lum + (p.1 - lum) * 1.35, lum + (p.2 - lum) * 1.35)
                let x0: Double = Double(i) * cell + inset, y0: Double = Double(j) * cell + inset
                let x1: Double = Double(i + 1) * cell - inset, y1: Double = Double(j + 1) * cell - inset
                var under = Path(); under.move(to: CGPoint(x: x0, y: y0)); under.addLine(to: CGPoint(x: x1, y: y1))
                ctx.stroke(under, with: .color(col((c.0 * 0.78, c.1 * 0.78, c.2 * 0.78))), style: thread)
                var over = Path(); over.move(to: CGPoint(x: x1, y: y0)); over.addLine(to: CGPoint(x: x0, y: y1))
                ctx.stroke(over, with: .color(col(c)), style: thread)
            }
        }
    }

    // MARK: 14 low-poly — drifting jittered facets

    static func lowPoly(_ ctx: GraphicsContext, _ size: CGSize, _ g: PixelGrid, _ k: Double, _ t: Double) {
        let W = Double(size.width), H = Double(size.height)
        let cols: Int = max(4, Int(28 * k))
        let rows: Int = max(2, Int((Double(cols) * H / W).rounded()))
        let cw: Double = W / Double(cols), chH: Double = H / Double(rows)
        let s = g.resized(cols: max(16, Int(112 * k)), fitting: size)
        func vertex(_ i: Int, _ j: Int) -> CGPoint {
            var x: Double = Double(i) * cw, y: Double = Double(j) * chH
            let n: Int = j * 389 + i * 53
            let phase: Double = h(n + 9) * 6.283
            if i > 0 && i < cols { x += (h(n) - 0.5) * cw * 0.66 + sin(t * 0.9 + phase) * cw * 0.08 }
            if j > 0 && j < rows { y += (h(n + 1) - 0.5) * chH * 0.66 + cos(t * 0.8 + phase) * chH * 0.08 }
            return CGPoint(x: x, y: y)
        }
        func facet(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ seed: Int) {
            let u: Double = Double(a.x + b.x + c.x) / 3 / W, v: Double = Double(a.y + b.y + c.y) / 3 / H
            let p = s.rgbAt(u: min(0.999, u), v: min(0.999, v))
            let shade: Double = 0.93 + 0.14 * h(seed)
            var tri = Path(); tri.move(to: a); tri.addLine(to: b); tri.addLine(to: c); tri.closeSubpath()
            let paint = GraphicsContext.Shading.color(col((p.0 * shade, p.1 * shade, p.2 * shade)))
            ctx.fill(tri, with: paint)
            ctx.stroke(tri, with: paint, lineWidth: 1)
        }
        for j in 0..<rows {
            for i in 0..<cols {
                let a = vertex(i, j), b = vertex(i + 1, j), c = vertex(i + 1, j + 1), d = vertex(i, j + 1)
                let seed: Int = j * 211 + i * 17
                if (i + j) % 2 == 0 { facet(a, b, c, seed); facet(a, c, d, seed + 1) }
                else { facet(a, b, d, seed); facet(b, c, d, seed + 1) }
            }
        }
    }

    // MARK: 15 blueprint — Sobel edges on cyanotype

    static func blueprint(_ ctx: GraphicsContext, _ size: CGSize, _ g: PixelGrid, _ k: Double) {
        let W = Double(size.width), H = Double(size.height)
        // works at the grid's native resolution (up to 960 wide) — pass a fine grid for crisp lines
        let s = g.resized(cols: min(g.cols, max(16, Int(960 * k))), fitting: size)
        let w: Int = s.cols, hh: Int = s.rows
        var lum = [Float](repeating: 0, count: w * hh)
        for i in 0..<(w * hh) {
            let r = Float(s.data[i * 4]), gr = Float(s.data[i * 4 + 1]), b = Float(s.data[i * 4 + 2])
            lum[i] = (0.299 * r + 0.587 * gr + 0.114 * b) / 255
        }
        let gain: Float = 2.6 * Float(w) / 240          // thinner gradients at higher res need more gain
        var px = [UInt8](repeating: 255, count: w * hh * 4)
        for y in 0..<hh {
            let y0: Int = max(0, y - 1) * w, y1: Int = y * w, y2: Int = min(hh - 1, y + 1) * w
            for x in 0..<w {
                let xl: Int = max(0, x - 1), xr: Int = min(w - 1, x + 1)
                let a: Float = lum[y0 + xl], b: Float = lum[y0 + x], c: Float = lum[y0 + xr]
                let d: Float = lum[y1 + xl], f: Float = lum[y1 + xr]
                let g0: Float = lum[y2 + xl], h0: Float = lum[y2 + x], i0: Float = lum[y2 + xr]
                let gx: Float = (c + 2 * f + i0) - (a + 2 * d + g0)
                let gy: Float = (g0 + 2 * h0 + i0) - (a + 2 * b + c)
                let e: Float = min(1, max(0, (gx * gx + gy * gy).squareRoot() * gain - 0.22) * 1.3)   // noise floor
                let base: Float = 0.78 + 0.3 * lum[y1 + x]
                let o: Int = (y1 + x) * 4
                px[o] = UInt8(min(255, (0.04 * base + e * 0.92) * 255))
                px[o + 1] = UInt8(min(255, (0.20 * base + e * 0.78) * 255))
                px[o + 2] = UInt8(min(255, (0.52 * base + e * 0.48) * 255))
            }
        }
        let out = PixelGrid(cols: w, rows: hh, data: px)
        image(ctx, out, size, smooth: true)
        let step: Double = W / 48
        var minor = Path(), major = Path()
        var n = 0
        var x: Double = 0
        while x <= W {
            if n % 4 == 0 { major.move(to: CGPoint(x: x, y: 0)); major.addLine(to: CGPoint(x: x, y: H)) }
            else { minor.move(to: CGPoint(x: x, y: 0)); minor.addLine(to: CGPoint(x: x, y: H)) }
            x += step; n += 1
        }
        n = 0
        var y: Double = 0
        while y <= H {
            if n % 4 == 0 { major.move(to: CGPoint(x: 0, y: y)); major.addLine(to: CGPoint(x: W, y: y)) }
            else { minor.move(to: CGPoint(x: 0, y: y)); minor.addLine(to: CGPoint(x: W, y: y)) }
            y += step; n += 1
        }
        ctx.stroke(minor, with: .color(.white.opacity(0.07)), lineWidth: 1)
        ctx.stroke(major, with: .color(.white.opacity(0.16)), lineWidth: 1)
    }

    // MARK: 16 thermal — luminance through an iron palette

    static let iron: [(Double, RGB)] = [
        (0.0, (0.0, 0.0, 0.06)), (0.2, (0.24, 0.0, 0.50)), (0.45, (0.80, 0.05, 0.45)),
        (0.65, (1.0, 0.42, 0.0)), (0.85, (1.0, 0.86, 0.12)), (1.0, (1.0, 1.0, 1.0)),
    ]

    static func heat(_ v: Double) -> RGB {
        let x: Double = min(1, max(0, v))
        for n in 1..<iron.count where x <= iron[n].0 {
            let a = iron[n - 1], b = iron[n]
            let f: Double = (x - a.0) / (b.0 - a.0)
            return (a.1.0 + (b.1.0 - a.1.0) * f, a.1.1 + (b.1.1 - a.1.1) * f, a.1.2 + (b.1.2 - a.1.2) * f)
        }
        return iron[iron.count - 1].1
    }

    static func thermal(_ ctx: GraphicsContext, _ size: CGSize, _ g: PixelGrid, _ k: Double) {
        let W = Double(size.width), H = Double(size.height)
        let s = g.resized(cols: min(g.cols, max(12, Int(960 * k))), fitting: size)
        let out = s.mapped { r, gg, b, _, _ in heat(pow(0.299 * r + 0.587 * gg + 0.114 * b, 0.8) * 1.08) }
        image(ctx, out, size, smooth: true)
        let barW: Double = W * 0.012, x: Double = W * 0.955, y0: Double = H * 0.2, y1: Double = H * 0.8
        let stops = iron.map { Gradient.Stop(color: col($0.1), location: 1 - $0.0) }.reversed()
        let bar = Path(roundedRect: CGRect(x: x, y: y0, width: barW, height: y1 - y0), cornerRadius: barW * 0.3)
        ctx.fill(bar, with: .linearGradient(Gradient(stops: Array(stops)), startPoint: CGPoint(x: x, y: y0),
                                            endPoint: CGPoint(x: x, y: y1)))
        ctx.stroke(bar, with: .color(.white.opacity(0.8)), lineWidth: max(1, W / 960))
        let arm: Double = W * 0.016
        var cross = Path()
        cross.move(to: CGPoint(x: W / 2 - arm, y: H / 2)); cross.addLine(to: CGPoint(x: W / 2 - arm * 0.3, y: H / 2))
        cross.move(to: CGPoint(x: W / 2 + arm * 0.3, y: H / 2)); cross.addLine(to: CGPoint(x: W / 2 + arm, y: H / 2))
        cross.move(to: CGPoint(x: W / 2, y: H / 2 - arm)); cross.addLine(to: CGPoint(x: W / 2, y: H / 2 - arm * 0.3))
        cross.move(to: CGPoint(x: W / 2, y: H / 2 + arm * 0.3)); cross.addLine(to: CGPoint(x: W / 2, y: H / 2 + arm))
        ctx.stroke(cross, with: .color(.white.opacity(0.9)), lineWidth: max(1.5, W / 640))
    }
}
