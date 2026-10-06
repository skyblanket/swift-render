import SwiftUI

// MARK: - Playhead
//
// The only timeline view that reads `playback.t` (60 Hz while playing). With
// follow on, it page-flips the viewport when playback runs off the visible range,
// and brings the playhead back into view after a jump (keys, [ ], edit points).

struct PlayheadOverlay: View {
    @Bindable var model: ProjectModel
    @AppStorage(TimelinePrefs.follow) private var follow = true

    var body: some View {
        let p = model.playback
        let v = model.ui.viewport
        let x = v.x(p.t)
        Canvas { ctx, size in
            guard x >= -6, x <= size.width + 6 else { return }
            let r = TimelineLayout.rulerHeight
            var line = Path()
            line.move(to: CGPoint(x: x, y: 10)); line.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(line, with: .color(StudioStyle.playhead.opacity(0.9)), lineWidth: 1.25)
            // Head: a rounded tab in the ruler with a point at the tick baseline.
            var head = Path()
            head.move(to: CGPoint(x: x - 5.5, y: r - 18)); head.addLine(to: CGPoint(x: x + 5.5, y: r - 18))
            head.addLine(to: CGPoint(x: x + 5.5, y: r - 9)); head.addLine(to: CGPoint(x: x, y: r - 4))
            head.addLine(to: CGPoint(x: x - 5.5, y: r - 9)); head.closeSubpath()
            ctx.fill(head, with: .color(StudioStyle.playhead))
            ctx.stroke(head, with: .color(.black.opacity(0.35)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
        .onChange(of: p.t) { _, t in
            guard follow else { return }
            // Test before mutating: any write to the observed viewport redraws every lane.
            let v = model.ui.viewport
            guard t < v.start || t > v.end else { return }
            var nv = v
            if p.isPlaying { nv.follow(t) } else { nv.reveal(t...t, margin: max(24, v.width * 0.1)) }
            if nv != v { model.ui.viewport = nv }
        }
    }
}

/// UserDefaults keys for timeline preferences.
enum TimelinePrefs {
    static let follow = "timeline.followPlayhead"
}
