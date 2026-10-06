import SwiftUI

// MARK: - Lane renderer
//
// One Canvas per lane (a comment change never redraws the waveform). No per-event
// SwiftUI views: a lane draws its visible primitives into one GraphicsContext and
// hit-tests in code. Labels only on blocks wider than 40 pt, ≤ ~60 per draw.

struct LaneHit: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case clip, event, caption, comment, silence, audio, inOut }
    /// Which part of a range was grabbed (comment retiming).
    enum Part: Equatable, Sendable { case body, startHandle, endHandle }
    var kind: Kind
    var id: String
    var start: Double
    var end: Double
    var part: Part = .body
    /// Hover card: headline and secondary line.
    var title: String = ""
    var detail: String?
    /// Lane-local rect of the hit item (hover highlight); nil for points in time.
    var rect: CGRect?
}

protocol LaneRenderer {
    var title: String { get }
    var height: CGFloat { get }
    func draw(in ctx: inout GraphicsContext, size: CGSize, viewport: TimelineViewport)
    func hit(_ p: CGPoint, viewport: TimelineViewport) -> LaneHit?
}

extension LaneRenderer {
    func hit(_ p: CGPoint, viewport: TimelineViewport) -> LaneHit? { nil }
}

enum LaneDraw {
    static let maxLabels = 60
    static let labelFont = Font.system(size: 9.5, weight: .medium)

    /// Block rect for [a, b] seconds, clipped to the viewport (nil when off-screen).
    static func rect(viewport v: TimelineViewport, from a: Double, to b: Double, y: CGFloat, height: CGFloat) -> CGRect? {
        let x0 = max(-2, v.x(a)), x1 = min(v.width + 2, v.x(b))
        guard x1 > x0 - 0.5 else { return nil }
        return CGRect(x: x0, y: y, width: max(1.5, x1 - x0 - 1), height: height)
    }

    /// A rounded block from `a` to `b` seconds, clipped to the viewport.
    static func block(_ ctx: inout GraphicsContext, viewport v: TimelineViewport, from a: Double, to b: Double,
                      y: CGFloat, height: CGFloat, color: Color, label: String?, labels: inout Int,
                      stroke: Color? = nil, dashed: Bool = false, fill: Double = 0.32, trailing: String? = nil) {
        guard let r = rect(viewport: v, from: a, to: b, y: y, height: height) else { return }
        if r.width < 5, stroke == nil {
            // A sliver can't show an outline: draw a solid bar so dense passages read as texture.
            ctx.fill(Path(r), with: .color(color.opacity(min(1, fill + 0.3))))
            return
        }
        let path = Path(roundedRect: r, cornerRadius: min(3, height / 3))
        ctx.fill(path, with: .color(color.opacity(fill)))
        if r.height > 8 {
            // Top sheen: reads as a raised clip, not a flat rectangle.
            ctx.fill(Path(roundedRect: CGRect(x: r.minX + 1, y: r.minY + 1, width: max(0, r.width - 2), height: 1),
                          cornerRadius: 0.5), with: .color(.white.opacity(0.10)))
        }
        ctx.stroke(path, with: .color(stroke ?? color.opacity(0.75)),
                   style: StrokeStyle(lineWidth: stroke == nil ? 1 : 1.5, dash: dashed ? [3, 2] : []))
        if let label { self.label(&ctx, label, in: r, labels: &labels, trailing: trailing) }
    }

    /// Leading label clipped to `r`, plus an optional dimmer trailing note when it fits.
    static func label(_ ctx: inout GraphicsContext, _ label: String, in r: CGRect, labels: inout Int,
                      trailing: String? = nil, color: Color = .white.opacity(0.92), font: Font = labelFont) {
        guard r.width > 40, labels < maxLabels, !label.isEmpty else { return }
        labels += 1
        var c = ctx
        c.clip(to: Path(r.insetBy(dx: 3, dy: 0)))
        // Keep the label on screen when the block starts left of the viewport.
        let x = max(r.minX, 0) + 5
        let text = c.resolve(Text(label).font(font).foregroundStyle(color))
        let w = text.measure(in: CGSize(width: 2000, height: r.height)).width
        c.draw(text, at: CGPoint(x: x, y: r.midY), anchor: .leading)
        if let trailing, labels < maxLabels, r.maxX - (x + w) > 46 {
            labels += 1
            c.draw(Text(trailing).font(.system(size: 8.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45)),
                   at: CGPoint(x: r.maxX - 5, y: r.midY), anchor: .trailing)
        }
    }

    /// Diagonal stripes inside `r` (transitions, silences).
    static func hatch(_ ctx: inout GraphicsContext, _ r: CGRect, color: Color, spacing: CGFloat = 4, lineWidth: CGFloat = 1) {
        guard r.width > 0.5, r.height > 0.5 else { return }
        var c = ctx
        c.clip(to: Path(r))
        var p = Path()
        var x = r.minX - r.height
        while x < r.maxX {
            p.move(to: CGPoint(x: x, y: r.maxY)); p.addLine(to: CGPoint(x: x + r.height, y: r.minY))
            x += spacing
        }
        c.stroke(p, with: .color(color), lineWidth: lineWidth)
    }

    /// Centered placeholder text for an empty lane.
    static func empty(_ ctx: inout GraphicsContext, _ text: String, size: CGSize) {
        ctx.draw(Text(text).font(.system(size: 10)).foregroundStyle(.white.opacity(0.32)),
                 at: CGPoint(x: 10, y: size.height / 2), anchor: .leading)
    }

    /// Visible slice of a time-sorted array (binary search on start, generous on the left).
    static func visible<T>(_ items: [T], viewport v: TimelineViewport, start: (T) -> Double, end: (T) -> Double) -> ArraySlice<T> {
        let lo = v.start - 30, hi = v.end
        var a = 0, b = items.count
        while a < b { let m = (a + b) / 2; if start(items[m]) < lo { a = m + 1 } else { b = m } }
        var z = a
        while z < items.count, start(items[z]) <= hi { z += 1 }
        return items[a..<z]
    }

    /// "2.40 s" / "12 s" for hover cards and block trailers.
    static func seconds(_ d: Double) -> String {
        d >= 10 ? String(format: "%.0f s", d) : String(format: "%.2f s", d)
    }

    /// "00:02.20–00:04.60".
    static func range(_ a: Double, _ b: Double) -> String {
        abs(b - a) < 1e-6 ? StudioStyle.timecode(a) : "\(StudioStyle.timecode(a))–\(StudioStyle.timecode(b))"
    }
}
