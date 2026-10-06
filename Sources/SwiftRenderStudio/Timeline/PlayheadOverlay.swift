import SwiftUI

// MARK: - Playhead
//
// The only timeline view that reads `playback.t` (60 Hz while playing). With
// follow on, it page-flips the viewport when playback runs off the visible range,
// and brings the playhead back into view after a jump (keys, [ ], edit points).

struct PlayheadOverlay: View {
    @Bindable var model: ProjectModel
    /// Gutter before 0:00 (the lanes start this far right).
    var inset: CGFloat = 0
    /// Column-space top of the comments lane: the line breaks around any comment disc it
    /// crosses, so pins (the selected one above all) always draw over the playhead.
    var notesY: CGFloat? = nil
    @AppStorage(TimelinePrefs.follow) private var follow = true

    var body: some View {
        let p = model.playback
        let v = model.ui.viewport
        let x = (v.x(p.t) + inset).rounded() + 0.5
        Canvas { ctx, size in
            guard x >= inset - 6, x <= size.width + 6 else { return }
            let r = TimelineLayout.rulerHeight
            // A 1 pt line with a cap: a small rounded tab in the ruler.
            var line = Path()
            let half = CommentsLane.markerSize / 2 + 4
            let mid = notesY.map { $0 + CommentsLane(comments: []).height / 2 }
            let underPin = mid != nil && model.review.comments.contains { c in
                abs(v.x(c.t) + inset - x) < half
            }
            if let mid, underPin, mid - half > r {
                line.move(to: CGPoint(x: x, y: r - 8)); line.addLine(to: CGPoint(x: x, y: mid - half))
                line.move(to: CGPoint(x: x, y: mid + half)); line.addLine(to: CGPoint(x: x, y: size.height))
            } else {
                line.move(to: CGPoint(x: x, y: r - 8)); line.addLine(to: CGPoint(x: x, y: size.height))
            }
            ctx.stroke(line, with: .color(StudioStyle.playhead), lineWidth: 1)
            let cap = CGRect(x: x - 5, y: r - 19, width: 10, height: 12)
            ctx.fill(Path(roundedRect: cap, cornerRadius: 3, style: .continuous), with: .color(StudioStyle.playhead))
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
