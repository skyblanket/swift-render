import AppKit
import CoreImage
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
        let deadline = Date().addingTimeInterval(options.fakeHost || options.fakeProcessHost ? 20 : 240)
        // A failed first build or a dead host won't produce a frame: capture that state now.
        func stuck() -> Bool {
            if case .failed = model.host.state { return true }
            if case .failed = model.build.phase, model.host.active == nil { return true }
            return false
        }
        while model.info == nil, !stuck(), Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        if let at = options.at { model.playback.seek(at, precise: true) }
        while !model.playback.hasFrame, !stuck(), Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        if case .failed(let diags, let log) = model.build.phase {
            let rows = diags.map { "\($0.file):\($0.line):\($0.column): \($0.severity.rawValue): \($0.message)" }
            let tail = log.split(separator: "\n").suffix(15).joined(separator: "\n")
            FileHandle.standardError.write(Data("[studio] build failed:\n\(rows.joined(separator: "\n"))\n\(tail)\n".utf8))
        }
        if let seconds = options.playFor, model.playback.hasFrame { await play(model, seconds: seconds) }
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

    /// `--play-for s`: real-time playback through the active host, then a stats line.
    /// An offscreen window gets no display-link callbacks, so ticks come from here.
    private static func play(_ model: ProjectModel, seconds: Double) async {
        let p = model.playback
        let startT = p.t, streams = p.streamsStarted
        p.play()
        let end = Date().addingTimeInterval(seconds)
        while p.isPlaying, Date() < end {
            p.tick()
            try? await Task.sleep(for: .milliseconds(16))
        }
        let s = p.liveStats
        p.pause()
        print(String(format: "[studio] played %.2f→%.2f s: shown %d, dropped %d, %.1f ms/frame, target %d fps, width %.0f%%, streams %d%@",
                     startT, p.t, s.shown, s.dropped, s.msPerFrame, s.targetFPS, s.widthScale * 100,
                     p.streamsStarted - streams, s.note.map { " · \($0)" } ?? ""))
    }

    static func render(_ window: NSWindow) -> Data? {
        if ProcessInfo.processInfo.environment["SR_SNAPSHOT_METHOD"] == "cache" { return renderCached(window) }
        return renderLayers(window)
    }

    /// CALayer tree render: sees layer contents, but not WindowServer-composited materials,
    /// and ignores layer `filters`. Vibrant text and symbols (sidebar, inspector, toolbar
    /// glass) are drawn in a placeholder gray and turned into white-at-alpha by a
    /// `vibrantColorMatrix` filter, so those layers are rendered in a second pass and the
    /// matrix is applied with Core Image before compositing them back.
    static func renderLayers(_ window: NSWindow) -> Data? {
        guard let frameView = window.contentView?.superview, let root = frameView.layer else { return nil }
        let scale = window.backingScaleFactor
        let size = frameView.bounds.size
        let w = Int(size.width * scale), h = Int(size.height * scale)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func context() -> CGContext? {
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
            ctx.scaleBy(x: scale, y: scale)
            if !root.isGeometryFlipped && frameView.isFlipped {
                ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1)
            }
            return ctx
        }

        // Backdrop/glass layers are composited by the WindowServer and render as garbage
        // here; hide them so the dark base shows through.
        let hide = Set((ProcessInfo.processInfo.environment["SR_SNAPSHOT_HIDE"]
            ?? "CABackdropLayer,CASDFLayer,SDFLayer,CAChameleonLayer,CAPortalLayer,SDFPortalLayer,CASDFElementLayer")
            .split(separator: ",").map(String.init))
        var hidden: [CALayer] = []
        var vibrant: [(layer: CALayer, matrix: [Float])] = []
        func walk(_ l: CALayer) {
            guard !l.isHidden, l.opacity > 0 else { return }
            if hide.contains(String(describing: type(of: l))) { l.isHidden = true; hidden.append(l); return }
            if let m = vibrantMatrix(l) {
                l.isHidden = true; hidden.append(l)
                if m[18] > 0.001 { vibrant.append((l, m)) }       // alpha row ~0: an invisible tint
                return
            }
            l.sublayers?.forEach(walk)
        }
        walk(root)
        defer { hidden.forEach { $0.isHidden = false } }

        guard let base = context() else { return nil }
        base.saveGState()
        base.setFillColor(CGColor(gray: 0.13, alpha: 1))
        base.fill(CGRect(origin: .zero, size: size))
        root.render(in: base)
        base.restoreGState()
        guard var image = base.makeImage() else { return nil }

        // Second pass: one transparent layer per distinct matrix, recolored, then composited.
        let all = CGRect(x: 0, y: 0, width: w, height: h)
        let ci = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])
        for (matrix, members) in Dictionary(grouping: vibrant, by: { $0.matrix }) {
            guard let ctx = context() else { continue }
            for (layer, _) in members {
                ctx.saveGState()
                if let clip = clipRect(layer, in: root) { ctx.clip(to: clip) }
                ctx.concatenate(transform(from: layer, to: root))
                layer.isHidden = false
                layer.render(in: ctx)
                layer.isHidden = true
                ctx.restoreGState()
            }
            guard let raw = ctx.makeImage(), let f = CIFilter(name: "CIColorMatrix") else { continue }
            f.setValue(CIImage(cgImage: raw), forKey: kCIInputImageKey)
            let row = { (i: Int) in CIVector(x: CGFloat(matrix[i]), y: CGFloat(matrix[i + 1]),
                                             z: CGFloat(matrix[i + 2]), w: CGFloat(matrix[i + 3])) }
            f.setValue(row(0), forKey: "inputRVector"); f.setValue(row(5), forKey: "inputGVector")
            f.setValue(row(10), forKey: "inputBVector"); f.setValue(row(15), forKey: "inputAVector")
            f.setValue(CIVector(x: CGFloat(matrix[4]), y: CGFloat(matrix[9]), z: CGFloat(matrix[14]),
                                w: CGFloat(matrix[19])), forKey: "inputBiasVector")
            guard let out = f.outputImage?.cropped(to: all),
                  let tinted = ci.createCGImage(out, from: all),
                  let comp = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { continue }
            comp.draw(image, in: all)
            comp.draw(tinted, in: all)
            if let merged = comp.makeImage() { image = merged }
        }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// The 4x5 matrix of a layer's `vibrantColorMatrix` filter (a private CAFilter, read via KVC).
    private static func vibrantMatrix(_ l: CALayer) -> [Float]? {
        guard let filters = l.filters else { return nil }
        for case let f as NSObject in filters where (f.value(forKey: "name") as? String) == "vibrantColorMatrix" {
            guard let v = f.value(forKey: "inputColorMatrix") as? NSValue else { return nil }
            var m = [Float](repeating: 0, count: 20)
            m.withUnsafeMutableBytes { v.getValue($0.baseAddress!, size: $0.count) }
            return m
        }
        return nil
    }

    /// Affine map from `l`'s coordinate space to `root`'s (handles flips and offsets).
    private static func transform(from l: CALayer, to root: CALayer) -> CGAffineTransform {
        let o = root.convert(CGPoint.zero, from: l)
        let x = root.convert(CGPoint(x: 1, y: 0), from: l)
        let y = root.convert(CGPoint(x: 0, y: 1), from: l)
        return CGAffineTransform(a: x.x - o.x, b: x.y - o.y, c: y.x - o.x, d: y.y - o.y, tx: o.x, ty: o.y)
    }

    /// Intersection of every clipping ancestor's bounds, in `root` space (scroll views).
    private static func clipRect(_ l: CALayer, in root: CALayer) -> CGRect? {
        var r: CGRect? = nil
        var a = l.superlayer
        while let p = a, p !== root {
            if p.masksToBounds {
                let b = root.convert(p.bounds, from: p)
                r = r.map { $0.intersection(b) } ?? b
            }
            a = p.superlayer
        }
        return r
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
