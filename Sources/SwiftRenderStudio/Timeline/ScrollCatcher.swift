import AppKit
import SwiftUI

// MARK: - Scroll catcher
//
// Trackpad/mouse navigation for the timeline: scroll pans, ⌥-scroll and pinch zoom
// around the cursor. A local event monitor scoped to this view's frame, so clicks
// and drags still reach the lanes underneath (hitTest returns nil).

final class ScrollCatcherView: NSView {
    var onPan: ((CGFloat) -> Void)?
    var onZoom: ((Double, CGFloat) -> Void)?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] e in
            guard let self, e.window === self.window else { return e }
            let p = self.convert(e.locationInWindow, from: nil)
            guard self.bounds.contains(p) else { return e }
            switch e.type {
            case .magnify:
                self.onZoom?(1 + Double(e.magnification), p.x)
            case .scrollWheel:
                if e.modifierFlags.contains(.option) || e.modifierFlags.contains(.command) {
                    let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 8
                    self.onZoom?(pow(1.01, Double(dy)), p.x)
                } else {
                    // Horizontal swipe, or ⇧-scroll / plain vertical wheel → pan.
                    let raw = abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) ? e.scrollingDeltaX : e.scrollingDeltaY
                    let dx = e.hasPreciseScrollingDeltas ? raw : raw * 10
                    self.onPan?(-dx)
                }
            default: return e
            }
            return nil
        }
    }

    deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
}

struct ScrollCatcher: NSViewRepresentable {
    var onPan: (CGFloat) -> Void
    var onZoom: (Double, CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollCatcherView {
        let v = ScrollCatcherView()
        v.onPan = onPan; v.onZoom = onZoom
        return v
    }

    func updateNSView(_ v: ScrollCatcherView, context: Context) {
        v.onPan = onPan; v.onZoom = onZoom
    }
}
