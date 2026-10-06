import AppKit
import SwiftUI

// MARK: - Render panels in snapshots
//
// Sheets and popovers are separate windows that a window snapshot can't see, so for
// `--show render-sheet|renders` the panel is laid out in its own offscreen window,
// rendered with the same layer renderer, and composited where AppKit would put it
// (sheet under the toolbar, popover under the Renders button). `--render <preset>`
// runs a real export through the project CLI first, so the popover shows live progress.

@MainActor
enum RenderSnapshot {
    /// Starts `--render` and waits until it is ~40% through (or done with `--render-wait done`).
    static func prepare(model: ProjectModel, options: LaunchOptions) async {
        guard let preset = options.renderPreset, let scene = model.selectedScene else { return }
        let id = model.renders.enqueue(scene: scene, preset: preset, range: model.playback.inOut,
                                       build: .currentDebug, knobs: .useLive)
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline, let job = model.renders.job(id) {
            if job.isDone { break }
            if !options.renderWaitDone, let f = job.fraction, f >= 0.4, f < 1 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if let job = model.renders.job(id) {
            print("[studio] render \(job.preset.rawValue): \(job.state)\(job.isDone ? "" : " (captured mid-render)")")
            if case .failed = job.state { print(job.log.suffix(10).joined(separator: "\n")) }
        }
    }

    /// The window PNG with the requested panel composited over it.
    static func decorate(_ png: Data, window: NSWindow, model: ProjectModel, options: LaunchOptions) -> Data {
        guard let show = options.show else { return png }
        let panel: AnyView
        let isSheet: Bool
        switch show {
        case "render-sheet":
            panel = AnyView(RenderSheet(model: model))
            isSheet = true
        case "renders", "render-activity":
            panel = AnyView(RenderActivityList(model: model).background(Color(white: 0.165)))
            isSheet = false
        default:
            FileHandle.standardError.write(Data("[studio] unknown --show \(show) (render-sheet | renders)\n".utf8))
            return png
        }
        guard let base = NSBitmapImageRep(data: png)?.cgImage,
              let overlay = renderPanel(panel) else { return png }

        let scale = window.backingScaleFactor
        let size = window.frame.size
        let pw = CGFloat(overlay.width) / scale, ph = CGFloat(overlay.height) / scale
        let top: CGFloat = isSheet ? 52 : 60
        let x = isSheet ? (size.width - pw) / 2 : size.width - pw - 64
        let rect = CGRect(x: x, y: size.height - top - ph, width: pw, height: ph)   // CG: bottom-left origin
        let radius: CGFloat = isSheet ? 11 : 12

        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return png }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        ctx.scaleBy(x: scale, y: scale)
        if isSheet {
            // A sheet dims nothing on macOS, but sits on a deep shadow.
            ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 40, color: CGColor(gray: 0, alpha: 0.6))
        } else {
            ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 24, color: CGColor(gray: 0, alpha: 0.55))
        }
        let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(shape)
        if !isSheet { ctx.addPath(arrow(at: CGPoint(x: rect.maxX - 34, y: rect.maxY))) }
        ctx.setFillColor(CGColor(gray: 0.165, alpha: 1))
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0)
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.draw(overlay, in: rect)
        ctx.restoreGState()
        ctx.addPath(shape)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
        ctx.setLineWidth(1)
        ctx.strokePath()
        guard let out = ctx.makeImage() else { return png }
        return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:]) ?? png
    }

    private static func arrow(at tip: CGPoint) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: tip.x - 9, y: tip.y - 1))
        p.addLine(to: CGPoint(x: tip.x, y: tip.y + 9))
        p.addLine(to: CGPoint(x: tip.x + 9, y: tip.y - 1))
        p.closeSubpath()
        return p
    }

    /// Lays `view` out at its fitting size in an offscreen window and renders its layers.
    private static func renderPanel(_ view: AnyView) -> CGImage? {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return nil }
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        // One runloop turn so SwiftUI commits its layers.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        defer { window.orderOut(nil) }
        guard let data = SnapshotRunner.renderLayers(window) else { return nil }
        return NSBitmapImageRep(data: data)?.cgImage
    }
}
