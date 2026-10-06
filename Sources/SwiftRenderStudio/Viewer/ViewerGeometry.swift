import CoreGraphics
import Foundation
import SwiftRenderKit

// MARK: - Viewer geometry
//
// Where the canvas sits in the viewer for each zoom, how many pixels to ask the host
// for, and the region math the review tools share: regions are stored normalized to
// the canvas (0…1, origin top-left, y down — `ReviewRegion`), shown to agents in
// scene points (scenes are written in 1920×1080 points).

enum ViewerZoom: String, CaseIterable, Identifiable, Sendable {
    case fit, p50, p100, p200
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fit: return "Fit"
        case .p50: return "50%"
        case .p100: return "100%"
        case .p200: return "200%"
        }
    }
    /// Scene points per screen point; nil = fit.
    var scale: CGFloat? {
        switch self {
        case .fit: return nil
        case .p50: return 0.5
        case .p100: return 1
        case .p200: return 2
        }
    }
    /// Pixel-peeping: nearest-neighbor magnification at ≥200%.
    var nearest: Bool { self == .p200 }
}

enum ViewerGeometry {
    /// Air around the picture at Fit.
    static let fitInset: CGFloat = 16

    /// Canvas rect (view coordinates, y down) for `content` scene size inside `container`.
    static func canvasRect(container: CGSize, content: CGSize, zoom: ViewerZoom, inset: CGFloat = 0) -> CGRect {
        guard content.width > 0, content.height > 0 else { return .zero }
        let avail = CGSize(width: max(0, container.width - inset * 2), height: max(0, container.height - inset * 2))
        let s = zoom.scale ?? min(avail.width / content.width, avail.height / content.height)
        let size = CGSize(width: content.width * s, height: content.height * s)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// Pixel width to request so the canvas is sharp on this display (capped at native).
    static func pixelWidth(canvas: CGRect, backingScale: CGFloat, sceneWidth: Int) -> Int {
        max(16, min(sceneWidth, Int((canvas.width * backingScale).rounded())))
    }

    /// Longest edge, in device pixels, to request so the canvas is sharp on this display
    /// (Retina aware, capped at the scene's native size). The host's `maxWidth` caps the
    /// longest edge, so a portrait canvas asks for its height, not its width.
    static func pixelEdge(canvas: CGRect, backingScale: CGFloat, sceneSize: CGSize) -> Int {
        let native = Int(max(sceneSize.width, sceneSize.height).rounded())
        return max(16, min(native, Int((max(canvas.width, canvas.height) * backingScale).rounded())))
    }
}

enum RegionMath {
    /// View rect → normalized region, clamped to the canvas. Accepts reversed drags.
    static func normalize(_ rect: CGRect, in canvas: CGRect) -> ReviewRegion {
        guard canvas.width > 0, canvas.height > 0 else { return ReviewRegion(x: 0, y: 0, w: 0, h: 0) }
        let r = rect.standardized
        func nx(_ x: CGFloat) -> Double { Double(min(1, max(0, (x - canvas.minX) / canvas.width))) }
        func ny(_ y: CGFloat) -> Double { Double(min(1, max(0, (y - canvas.minY) / canvas.height))) }
        let x0 = nx(r.minX), x1 = nx(r.maxX), y0 = ny(r.minY), y1 = ny(r.maxY)
        return ReviewRegion(x: round4(x0), y: round4(y0), w: round4(x1 - x0), h: round4(y1 - y0))
    }

    /// Click without drag → a point pin (zero-size region).
    static func point(_ p: CGPoint, in canvas: CGRect) -> ReviewRegion {
        normalize(CGRect(origin: p, size: .zero), in: canvas)
    }

    /// Normalized region → view rect.
    static func rect(_ r: ReviewRegion, in canvas: CGRect) -> CGRect {
        CGRect(x: canvas.minX + CGFloat(r.x) * canvas.width, y: canvas.minY + CGFloat(r.y) * canvas.height,
               width: CGFloat(r.w) * canvas.width, height: CGFloat(r.h) * canvas.height)
    }

    /// Normalized region → scene points (what the agent prompt quotes).
    static func scenePoints(_ r: ReviewRegion, sceneSize: CGSize) -> CGRect {
        CGRect(x: (r.x * sceneSize.width).rounded(), y: (r.y * sceneSize.height).rounded(),
               width: (r.w * sceneSize.width).rounded(), height: (r.h * sceneSize.height).rounded())
    }

    static func isPoint(_ r: ReviewRegion) -> Bool { r.w == 0 && r.h == 0 }

    /// A drag shorter than this (points) is a click.
    static let clickSlop: CGFloat = 3

    /// "x .333 y .111 w .208 h .204 = 640,120 · 400×220 scene pt"
    static func describe(_ r: ReviewRegion, sceneSize: CGSize) -> String {
        func f(_ v: Double) -> String { String(format: "%.3f", v).replacingOccurrences(of: "0.", with: ".") }
        let p = scenePoints(r, sceneSize: sceneSize)
        if isPoint(r) { return "point \(f(r.x)), \(f(r.y)) = \(Int(p.minX)),\(Int(p.minY)) scene pt" }
        return "x \(f(r.x)) y \(f(r.y)) w \(f(r.w)) h \(f(r.h)) = \(Int(p.minX)),\(Int(p.minY)) · \(Int(p.width))×\(Int(p.height)) scene pt"
    }

    /// "768 × 389" in scene points (shown while ⌥ is held during a drag).
    static func sizeLabel(_ r: ReviewRegion, sceneSize: CGSize) -> String {
        let p = scenePoints(r, sceneSize: sceneSize)
        return "\(Int(p.width)) × \(Int(p.height))"
    }

    private static func round4(_ v: Double) -> Double { (v * 10_000).rounded() / 10_000 }
}
