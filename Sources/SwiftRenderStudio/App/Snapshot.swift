import AppKit
import SwiftUI
import SwiftRenderKit

// MARK: - Snapshot mode
//
// Builds the same ProjectWindowContent in an NSWindow placed off every screen, with
// the app as an accessory (no Dock icon, never activated), starts the project, waits
// for the first frame at `--at`, then writes a PNG of the whole window (title bar and
// toolbar included) and exits 0. `cacheDisplay` can't see CALayer contents set
// directly, so the current frame is composited back in at the frame layer's rect.

@MainActor
enum SnapshotRunner {
    static func run(_ options: LaunchOptions, out: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .darkAqua)

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let root = options.projectPath.map { Project.discover(from: $0)?.root ?? $0 }
            ?? Project.discover(from: cwd)?.root ?? cwd
        let model = ProjectModel(root: root, options: options)
        let size = NSSize(width: 1600, height: 1000)

        let hosting = NSHostingController(rootView: ProjectWindowContent(model: model))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.toolbarStyle = .unified
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.setContentSize(size)
        // Far off every screen: laid out and displayed, never seen, never key.
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()

        Task { @MainActor in
            let code = await capture(model: model, window: window, options: options, out: out)
            await model.shutdown()
            exit(code)
        }
        app.run()
    }

    private static func capture(model: ProjectModel, window: NSWindow, options: LaunchOptions, out: String) async -> Int32 {
        // ProjectWindowContent's .task starts the model; wait for a scene and a frame.
        let deadline = Date().addingTimeInterval(options.fakeHost ? 20 : 240)
        while model.info == nil, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        if let at = options.at { model.playback.seek(at, precise: true) }
        while !model.playback.hasFrame, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        // Let the sharpen pass land and SwiftUI settle.
        try? await Task.sleep(for: .milliseconds(700))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        guard let png = render(window) else {
            FileHandle.standardError.write(Data("[studio] snapshot failed to render\n".utf8))
            return 1
        }
        let url = URL(fileURLWithPath: out)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: url)
        } catch {
            FileHandle.standardError.write(Data("[studio] snapshot write failed: \(error)\n".utf8))
            return 1
        }
        let state = model.playback.hasFrame ? "frame f\(frameIndex(model.playback.t, fps: model.playback.fps))" : "NO FRAME"
        print("[studio] snapshot → \(out) (\(model.selectedScene ?? "no scene"), \(state), host \(model.host.state))")
        return model.playback.hasFrame ? 0 : 2
    }

    static func render(_ window: NSWindow) -> Data? {
        if ProcessInfo.processInfo.environment["SR_SNAPSHOT_METHOD"] == "cache" { return renderCached(window) }
        return renderLayers(window)
    }

    /// CALayer tree render: sees layer contents, but not WindowServer-composited materials.
    static func renderLayers(_ window: NSWindow) -> Data? {
        guard let frameView = window.contentView?.superview, let layer = frameView.layer else { return nil }
        let scale = window.backingScaleFactor
        let size = frameView.bounds.size
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.13, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        if layer.isGeometryFlipped == false && frameView.isFlipped {
            ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1)
        }
        if ProcessInfo.processInfo.environment["SR_SNAPSHOT_DEBUG"] == "1" {
            var counts: [String: Int] = [:]
            func walk(_ l: CALayer) { counts[String(describing: type(of: l)), default: 0] += 1; l.sublayers?.forEach(walk) }
            walk(layer)
            print(counts.sorted { $0.key < $1.key })
        }
        // Backdrop/glass layers are composited by the WindowServer and render as garbage
        // here; hide them for the capture so the dark base shows through.
        let hide = (ProcessInfo.processInfo.environment["SR_SNAPSHOT_HIDE"] ?? "CABackdropLayer,CASDFLayer,SDFLayer,CAChameleonLayer,CAPortalLayer,SDFPortalLayer,CASDFElementLayer")
            .split(separator: ",").map(String.init)
        var hidden: [CALayer] = []
        func walkHide(_ l: CALayer) {
            if hide.contains(String(describing: type(of: l))), !l.isHidden { l.isHidden = true; hidden.append(l) }
            l.sublayers?.forEach(walkHide)
        }
        walkHide(layer)
        layer.render(in: ctx)
        hidden.forEach { $0.isHidden = false }
        guard let img = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }

    static func renderCached(_ window: NSWindow) -> Data? {
        guard let content = window.contentView, let frameView = content.superview ?? window.contentView else { return nil }
        let bounds = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        frameView.cacheDisplay(in: bounds, to: rep)

        // Composite CALayer frame images (FrameLayerView) that cacheDisplay skipped.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return rep.representation(using: .png, properties: [:]) }
        NSGraphicsContext.current = ctx
        for v in frameLayerViews(in: frameView) {
            guard let img = v.image else { continue }
            let canvas = v.canvasRect                                    // flipped view coords
            let inWindow = v.convert(canvas, to: nil)
            let inFrame = frameView.convert(inWindow, from: nil)
            let r = frameView.isFlipped
                ? NSRect(x: inFrame.minX, y: bounds.height - inFrame.maxY, width: inFrame.width, height: inFrame.height)
                : inFrame
            let clip = frameView.convert(v.convert(v.bounds, to: nil), from: nil)
            ctx.cgContext.saveGState()
            ctx.cgContext.clip(to: frameView.isFlipped
                ? NSRect(x: clip.minX, y: bounds.height - clip.maxY, width: clip.width, height: clip.height) : clip)
            ctx.cgContext.interpolationQuality = .high
            ctx.cgContext.draw(img, in: aspectFit(CGSize(width: img.width, height: img.height), in: r))
            ctx.cgContext.restoreGState()
        }
        ctx.flushGraphics()
        return rep.representation(using: .png, properties: [:])
    }

    private static func frameLayerViews(in v: NSView) -> [FrameLayerView] {
        var out: [FrameLayerView] = []
        if let f = v as? FrameLayerView { out.append(f) }
        for s in v.subviews { out += frameLayerViews(in: s) }
        return out
    }

    private static func aspectFit(_ size: CGSize, in r: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return r }
        let s = min(r.width / size.width, r.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
    }
}
