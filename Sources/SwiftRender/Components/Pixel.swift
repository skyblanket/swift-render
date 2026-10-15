import SwiftUI

// MARK: - PixelCanvas

/// Draws on a logical low-res grid inside a SwiftUI `Canvas`: every call takes
/// logical pixel units and is snapped to whole device pixels, so art stays crisp.
///
///     Canvas { ctx, size in
///         var px = PixelCanvas(ctx: ctx, s: size.width / 240)   // 240-wide grid
///         px.rect(10, 10, 4, 4, .red)
///         px.text("HELLO", 20, 20, scale: 2, .white, shadow: .black)
///     }
public struct PixelCanvas {
    /// The Canvas graphics context being drawn into.
    public let ctx: GraphicsContext
    /// Device pixels per logical pixel.
    public let s: Double
    /// Logical offset applied to every draw (camera shake, scrolling).
    public var ox = 0.0, oy = 0.0

    /// Wraps `ctx` with `s` device pixels per logical pixel and an optional offset.
    public init(ctx: GraphicsContext, s: Double, ox: Double = 0, oy: Double = 0) {
        self.ctx = ctx; self.s = s; self.ox = ox; self.oy = oy
    }

    /// Fills the whole canvas with `c`.
    public func fillAll(_ c: Color) { rawRect(-1, -1, 100_000, 100_000, c) }

    /// Fills a rect in raw device coordinates, ignoring scale, offset and snapping.
    public func rawRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ c: Color) {
        ctx.fill(Path(CGRect(x: x, y: y, width: w, height: h)), with: .color(c))
    }

    /// Fills a logical-pixel rect, snapped to whole device pixels.
    public func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ c: Color) {
        let x0 = ((x + ox) * s).rounded(), y0 = ((y + oy) * s).rounded()
        let x1 = ((x + ox + w) * s).rounded(), y1 = ((y + oy + h) * s).rounded()
        ctx.fill(Path(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)), with: .color(c))
    }

    /// Draws a 1-logical-pixel outline of the rect.
    public func frame(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ c: Color) {
        rect(x, y, w, 1, c); rect(x, y + h - 1, w, 1, c)
        rect(x, y, 1, h, c); rect(x + w - 1, y, 1, h, c)
    }

    /// Draws ASCII-art `rows` at (x, y): each character maps through `pal` (unmapped = transparent), `sc` logical pixels per cell.
    public func sprite(_ rows: [String], _ pal: [Character: Color], _ x: Double, _ y: Double, _ sc: Double) {
        for (r, row) in rows.enumerated() {
            for (c, ch) in row.enumerated() {
                guard let col = pal[ch] else { continue }
                rect(x + Double(c) * sc, y + Double(r) * sc, sc, sc, col)
            }
        }
    }

    /// Filled pixel-circle of diameter `d` logical pixels centred on (cx, cy).
    public func dot(_ cx: Double, _ cy: Double, _ d: Double, _ c: Color) {
        if d < 0.8 { return }
        if d <= 1.6 { rect(cx, cy, 1, 1, c); return }
        let r = d / 2
        let ri = Int(r.rounded(.up))
        for j in -ri..<ri {
            let yy = Double(j) + 0.5
            let w = (r * r - yy * yy).squareRoot()
            if w < 0.5 { continue }
            let wi = (w * 2).rounded()
            rect(cx - (wi / 2).rounded(), cy + Double(j), wi, 1, c)
        }
    }

    /// Diamond-lattice halftone screen. `value` is 0…1.2 (dot size / cell); ≥1.15 fills solid.
    public func halftone(_ x0: Double, _ y0: Double, _ w: Double, _ h: Double, cell: Double,
                  value: (Double, Double) -> Double, color: (Double, Double) -> Color) {
        let rows = Int(h / cell), cols = Int(w / cell) + 1
        for j in 0..<rows {
            let y = y0 + (Double(j) + 0.5) * cell
            for i in 0..<cols {
                let x = x0 + (Double(i) + (j % 2 == 0 ? 0.5 : 0)) * cell
                let v = value(x, y)
                if v <= 0.08 { continue }
                let c = color(x, y)
                if v >= 1.15 { rect((x - cell / 2).rounded(), (y - cell / 2).rounded(), cell, cell, c) }
                else { dot(x.rounded(), y.rounded(), v * cell * 1.25, c) }
            }
        }
    }

    /// Bitmap type whose font pixels fade from solid to halftone dots top → bottom.
    public func htText(_ str: String, _ x: Double, _ y: Double, scale: Double, _ c: Color,
                shadow: Color? = nil, t: Double) {
        if let sh = shadow { htGlyphs(str, x + scale, y + scale, scale, sh, t: t, wave: false) }
        htGlyphs(str, x, y, scale, c, t: t, wave: true)
    }

    private func htGlyphs(_ str: String, _ x: Double, _ y: Double, _ sc: Double, _ c: Color,
                          t: Double, wave: Bool) {
        var cx = x
        for (gi, ch) in str.enumerated() {
            if let g = PixelFont.glyphs[ch] {
                for (r, row) in g.enumerated() {
                    for (col, v) in row.enumerated() where v == "X" {
                        var lvl = 1 - 0.5 * Double(r) / 6
                        if wave { lvl += 0.08 * sin(t * 3.2 + Double(col) * 0.9 + Double(gi) * 0.7) }
                        let px = cx + Double(col) * sc, py = y + Double(r) * sc
                        if sc >= 3 {
                            if lvl > 0.76 { rect(px, py, sc, sc, c) }
                            else if lvl > 0.5 { rect(px + 1, py, 1, sc, c); rect(px, py + 1, sc, 1, c) }
                            else if lvl > 0.28 { rect(px, py, 2, 2, c) }
                            else { rect(px + 1, py + 1, 1, 1, c) }
                        } else {
                            if lvl > 0.42 { rect(px, py, sc, sc, c) }
                            else { rect(px, py, 1, 1, c) }
                        }
                    }
                }
            }
            cx += 6 * sc
        }
    }

    /// Draws `str` in `PixelFont` at `scale`, with an optional drop shadow offset by one scaled pixel.
    public func text(_ str: String, _ x: Double, _ y: Double, scale: Double, _ c: Color, shadow: Color? = nil) {
        if let sh = shadow { glyphs(str, x + scale, y + scale, scale, sh) }
        glyphs(str, x, y, scale, c)
    }

    private func glyphs(_ str: String, _ x: Double, _ y: Double, _ sc: Double, _ c: Color) {
        var cx = x
        for ch in str {
            if let g = PixelFont.glyphs[ch] {
                for (r, row) in g.enumerated() {
                    for (col, v) in row.enumerated() where v == "X" {
                        rect(cx + Double(col) * sc, y + Double(r) * sc, sc, sc, c)
                    }
                }
            }
            cx += 6 * sc
        }
    }
}

/// 5×7 bitmap font: A–Z, 0–9 and . , ! ? : - + '
public enum PixelFont {
    /// Width in logical pixels of `text` at `scale`.
    public static func width(_ text: String, scale: Double = 1) -> Double { Double(max(0, text.count * 6 - 1)) * scale }

    /// Glyph bitmaps: seven 5-character rows per character, `X` = filled.
    public static let glyphs: [Character: [String]] = {
        let raw: [Character: String] = [
            "A": ".XXX./X...X/X...X/XXXXX/X...X/X...X/X...X",
            "B": "XXXX./X...X/X...X/XXXX./X...X/X...X/XXXX.",
            "C": ".XXXX/X..../X..../X..../X..../X..../.XXXX",
            "D": "XXXX./X...X/X...X/X...X/X...X/X...X/XXXX.",
            "E": "XXXXX/X..../X..../XXXX./X..../X..../XXXXX",
            "F": "XXXXX/X..../X..../XXXX./X..../X..../X....",
            "G": ".XXXX/X..../X..../X.XXX/X...X/X...X/.XXXX",
            "H": "X...X/X...X/X...X/XXXXX/X...X/X...X/X...X",
            "I": "XXXXX/..X../..X../..X../..X../..X../XXXXX",
            "J": "..XXX/...X./...X./...X./...X./X..X./.XX..",
            "K": "X...X/X..X./X.X../XX.../X.X../X..X./X...X",
            "L": "X..../X..../X..../X..../X..../X..../XXXXX",
            "M": "X...X/XX.XX/X.X.X/X.X.X/X...X/X...X/X...X",
            "N": "X...X/XX..X/X.X.X/X..XX/X...X/X...X/X...X",
            "O": ".XXX./X...X/X...X/X...X/X...X/X...X/.XXX.",
            "P": "XXXX./X...X/X...X/XXXX./X..../X..../X....",
            "Q": ".XXX./X...X/X...X/X...X/X.X.X/X..X./.XX.X",
            "R": "XXXX./X...X/X...X/XXXX./X.X../X..X./X...X",
            "S": ".XXXX/X..../X..../.XXX./....X/....X/XXXX.",
            "T": "XXXXX/..X../..X../..X../..X../..X../..X..",
            "U": "X...X/X...X/X...X/X...X/X...X/X...X/.XXX.",
            "V": "X...X/X...X/X...X/X...X/X...X/.X.X./..X..",
            "W": "X...X/X...X/X...X/X.X.X/X.X.X/XX.XX/X...X",
            "X": "X...X/X...X/.X.X./..X../.X.X./X...X/X...X",
            "Y": "X...X/X...X/.X.X./..X../..X../..X../..X..",
            "Z": "XXXXX/....X/...X./..X../.X.../X..../XXXXX",
            "0": ".XXX./X...X/X..XX/X.X.X/XX..X/X...X/.XXX.",
            "1": "..X../.XX../..X../..X../..X../..X../.XXX.",
            "2": ".XXX./X...X/....X/...X./..X../.X.../XXXXX",
            "3": "XXXX./....X/....X/.XXX./....X/....X/XXXX.",
            "4": "...X./..XX./.X.X./X..X./XXXXX/...X./...X.",
            "5": "XXXXX/X..../XXXX./....X/....X/X...X/.XXX.",
            "6": ".XXX./X..../X..../XXXX./X...X/X...X/.XXX.",
            "7": "XXXXX/....X/...X./..X../.X.../.X.../.X...",
            "8": ".XXX./X...X/X...X/.XXX./X...X/X...X/.XXX.",
            "9": ".XXX./X...X/X...X/.XXXX/....X/....X/.XXX.",
            ".": "...../...../...../...../...../.XX../.XX..",
            ",": "...../...../...../...../.XX../..X../.X...",
            "!": "..X../..X../..X../..X../..X../...../..X..",
            "?": ".XXX./X...X/....X/...X./..X../...../..X..",
            ":": "...../.XX../.XX../...../.XX../.XX../.....",
            "-": "...../...../...../XXXXX/...../...../.....",
            "+": "...../..X../..X../XXXXX/..X../..X../.....",
            "'": "..X../..X../.X.../...../...../...../.....",
        ]
        return raw.mapValues { $0.split(separator: "/").map(String.init) }
    }()
}
