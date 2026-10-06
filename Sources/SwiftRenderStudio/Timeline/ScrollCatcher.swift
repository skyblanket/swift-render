import AppKit
import SwiftUI

// MARK: - Scroll catcher
//
// Trackpad/mouse navigation for the timeline: horizontal swipe and ⇧-scroll pan,
// vertical scroll moves the lanes when they overflow (else pans, so a plain mouse
// wheel still travels in time), ⌥/⌘-scroll and pinch zoom around the cursor. A
// local event monitor scoped to this view's frame, so clicks and drags still reach
// the lanes underneath (hitTest returns nil).

enum ScrollRoute: Equatable {
    case pan(CGFloat)
    case zoom(Double)
    case vertical(CGFloat)
}

enum ScrollRouting {
    /// Map one scroll event to an action. Deltas are AppKit's `scrollingDelta*`
    /// (natural direction already applied); line-based wheels are scaled up.
    static func route(dx: CGFloat, dy: CGFloat, precise: Bool, option: Bool, command: Bool, shift: Bool,
                      canScrollVertically: Bool) -> ScrollRoute? {
        if option || command {
            let d = precise ? dy : dy * 8
            return d == 0 ? nil : .zoom(pow(1.01, Double(d)))
        }
        let scale: CGFloat = precise ? 1 : 10
        if shift || abs(dx) > abs(dy) {
            let raw = abs(dx) >= abs(dy) ? dx : dy
            return raw == 0 ? nil : .pan(-raw * scale)
        }
        guard dy != 0 else { return nil }
        return canScrollVertically ? .vertical(-dy * scale) : .pan(-dy * scale)
    }
}

final class ScrollCatcherView: NSView {
    var onPan: ((CGFloat) -> Void)?
    var onZoom: ((Double, CGFloat) -> Void)?
    /// Vertical lane scroll; nil or no overflow → vertical wheel pans instead.
    var onScrollY: ((CGFloat) -> Void)?
    var canScrollY: () -> Bool = { false }
    /// x offset of the lanes column inside this view (zoom anchors are lane-local).
    var lanesX: CGFloat = 0
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
            let x = p.x - self.lanesX
            switch e.type {
            case .magnify:
                self.onZoom?(1 + Double(e.magnification), x)
            case .scrollWheel:
                let f = e.modifierFlags
                switch ScrollRouting.route(dx: e.scrollingDeltaX, dy: e.scrollingDeltaY,
                                           precise: e.hasPreciseScrollingDeltas, option: f.contains(.option),
                                           command: f.contains(.command), shift: f.contains(.shift),
                                           canScrollVertically: self.onScrollY != nil && self.canScrollY()) {
                case .pan(let dx): self.onPan?(dx)
                case .zoom(let factor): self.onZoom?(factor, x)
                case .vertical(let dy): self.onScrollY?(dy)
                case nil: break
                }
            default: return e
            }
            return nil
        }
    }

    deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
}

struct ScrollCatcher: NSViewRepresentable {
    var lanesX: CGFloat = 0
    var onPan: (CGFloat) -> Void
    var onZoom: (Double, CGFloat) -> Void
    var onScrollY: ((CGFloat) -> Void)? = nil
    var canScrollY: () -> Bool = { false }

    func makeNSView(context: Context) -> ScrollCatcherView {
        let v = ScrollCatcherView()
        updateNSView(v, context: context)
        return v
    }

    func updateNSView(_ v: ScrollCatcherView, context: Context) {
        v.onPan = onPan; v.onZoom = onZoom; v.onScrollY = onScrollY; v.canScrollY = canScrollY; v.lanesX = lanesX
    }
}
