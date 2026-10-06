import Accelerate
import AppKit
import QuartzCore
import SwiftUI

// MARK: - Frame layer
//
// Frames go straight onto a CALayer — never through SwiftUI state — so a 60 Hz
// playhead doesn't re-run view bodies. Implicit animations are disabled on the
// image layer (otherwise every swap is a 0.25 s crossfade). The view also owns the
// display link that drives `PlaybackEngine.tick()` while playing.

final class FrameLayerView: NSView {
    private let imageLayer = CALayer()
    private var link: CADisplayLink?
    weak var engine: PlaybackEngine? {
        didSet { attachEngine() }
    }
    var zoom: ViewerZoom = .fit { didSet { needsLayout = true } }
    var sceneSize = CGSize(width: 1920, height: 1080) { didSet { needsLayout = true } }
    private(set) var image: CGImage?
    /// The last 2 shown surfaces: a surface on screen (or just replaced, while CA may
    /// still composite it) must never go back to the pool.
    private var heldSurfaces: [FrameSurface] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.backgroundColor = NSColor.black.cgColor
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .trilinear
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// Canvas rect in view coordinates (y down) for the current zoom.
    var canvasRect: CGRect {
        ViewerGeometry.canvasRect(container: bounds.size, content: sceneSize, zoom: zoom, inset: zoom == .fit ? ViewerGeometry.fitInset : 0)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = canvasRect
        imageLayer.magnificationFilter = zoom.nearest ? .nearest : .linear
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
        reportDisplayWidth()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reportDisplayWidth()
    }

    private func reportDisplayWidth() {
        guard let engine else { return }
        let scale = window?.backingScaleFactor ?? 2
        let env = ProcessInfo.processInfo.environment
        let sceneScale = env["SR_PREVIEW_SCALE"].flatMap(Double.init) ?? 1
        let size = CGSize(width: sceneSize.width * sceneScale, height: sceneSize.height * sceneScale)
        let edge = env["SR_PREVIEW_DISPLAY_WIDTH"].flatMap(Int.init)
            ?? ViewerGeometry.pixelEdge(canvas: canvasRect, backingScale: scale, sceneSize: size)
        if engine.displayWidth != edge { engine.displayWidth = edge }
    }

    /// A decoded frame: its IOSurface goes straight to the layer when it has one (no
    /// Core Animation copy); `image` stays current for snapshots and covers.
    func show(frame f: DecodedFrame) {
        guard let surface = f.surface else { show(f.image); return }
        image = f.image
        heldSurfaces.append(surface)
        if heldSurfaces.count > 2 { heldSurfaces.removeFirst(heldSurfaces.count - 2) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = surface.surface
        CATransaction.commit()
    }

    func show(_ img: CGImage?) {
        image = img
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = img
        CATransaction.commit()
    }

    /// Scene switch without a poster: the old picture, small, blurred and desaturated, so it
    /// reads as "on its way" and never as the new scene. A real frame replaces it.
    func showCover() {
        guard let img = image, let cover = Self.cover(img) else { return }
        show(cover)
    }

    /// Longest edge of the cover bitmap: the layer scales it up (linear), which is most of the blur.
    static let coverEdge = 96

    /// The cover, on the CPU and synchronously (a GPU Core Image pass came back black in some
    /// contexts): downscale into a small premultiplied BGRA bitmap, two tent passes, half the
    /// saturation. ~0.1 ms; the result never shares memory with `img`.
    static func cover(_ img: CGImage) -> CGImage? {
        let s = CGFloat(coverEdge) / CGFloat(max(img.width, img.height, 1))
        let w = max(1, Int((CGFloat(img.width) * s).rounded())), h = max(1, Int((CGFloat(img.height) * s).rounded()))
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: FrameDecoder.sRGB, bitmapInfo: info),
              let base = ctx.data else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var scratch = [UInt8](repeating: 0, count: w * h * 4)
        var src = vImage_Buffer(data: base, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
        let kernel = UInt32(max(3, (min(w, h) / 6) | 1))
        scratch.withUnsafeMutableBytes { raw in
            var tmp = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
            for _ in 0..<2 {
                vImageTentConvolve_ARGB8888(&src, &tmp, nil, 0, 0, kernel, kernel, nil, vImage_Flags(kvImageEdgeExtend))
                vImageTentConvolve_ARGB8888(&tmp, &src, nil, 0, 0, kernel, kernel, nil, vImage_Flags(kvImageEdgeExtend))
            }
        }
        // Half saturation: mix each channel halfway to the pixel's luma (BGRA in memory).
        let px = base.bindMemory(to: UInt8.self, capacity: w * h * 4)
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let b = Int(px[i]), g = Int(px[i + 1]), r = Int(px[i + 2])
            let y = (r * 54 + g * 183 + b * 19) >> 8
            px[i] = UInt8((b + y) >> 1); px[i + 1] = UInt8((g + y) >> 1); px[i + 2] = UInt8((r + y) >> 1)
        }
        return ctx.makeImage()
    }

    private func attachEngine() {
        guard let engine else { return }
        engine.onFrame = { [weak self] f in self?.show(frame: f) }
        engine.onCover = { [weak self] in self?.showCover() }
        engine.onPlayStateChange = { [weak self] playing in self?.link?.isPaused = !playing }
        if let f = engine.currentFrame { show(frame: f) }
        link?.isPaused = !engine.isPlaying
        reportDisplayWidth()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, link == nil {
            let l = displayLink(target: self, selector: #selector(step(_:)))
            l.add(to: .main, forMode: .common)
            l.isPaused = !(engine?.isPlaying ?? false)
            link = l
        } else if window == nil {
            link?.invalidate()
            link = nil
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        MainActor.assumeIsolated { engine?.tick() }
    }
}

struct FrameLayerRepresentable: NSViewRepresentable {
    var engine: PlaybackEngine
    var zoom: ViewerZoom
    var sceneSize: CGSize

    func makeNSView(context: Context) -> FrameLayerView {
        let v = FrameLayerView(frame: .zero)
        v.sceneSize = sceneSize
        v.zoom = zoom
        v.engine = engine
        return v
    }

    func updateNSView(_ v: FrameLayerView, context: Context) {
        if v.engine !== engine { v.engine = engine }
        if v.zoom != zoom { v.zoom = zoom }
        if v.sceneSize != sceneSize { v.sceneSize = sceneSize }
    }
}
