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
        engine.displayWidth = ViewerGeometry.pixelWidth(canvas: canvasRect, backingScale: scale,
                                                        sceneWidth: Int(sceneSize.width))
    }

    func show(_ img: CGImage?) {
        image = img
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = img
        CATransaction.commit()
    }

    private func attachEngine() {
        guard let engine else { return }
        engine.onFrame = { [weak self] f in self?.show(f.image) }
        engine.onPlayStateChange = { [weak self] playing in self?.link?.isPaused = !playing }
        if let f = engine.currentFrame { show(f.image) }
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
