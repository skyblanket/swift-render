import SwiftUI

// MARK: - Playhead
//
// The only timeline view that reads `playback.t` (60 Hz while playing). It also
// page-flips the viewport when playback runs off the visible range.

struct PlayheadOverlay: View {
    @Bindable var model: ProjectModel

    var body: some View {
        let p = model.playback
        let v = model.ui.viewport
        let x = v.x(p.t)
        Canvas { ctx, size in
            guard x >= -1, x <= size.width + 1 else { return }
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(line, with: .color(StudioStyle.playhead), lineWidth: 1.25)
            var head = Path()
            head.move(to: CGPoint(x: x - 5.5, y: 0)); head.addLine(to: CGPoint(x: x + 5.5, y: 0))
            head.addLine(to: CGPoint(x: x + 5.5, y: 7)); head.addLine(to: CGPoint(x: x, y: 12))
            head.addLine(to: CGPoint(x: x - 5.5, y: 7)); head.closeSubpath()
            ctx.fill(head, with: .color(StudioStyle.playhead))
        }
        .allowsHitTesting(false)
        .onChange(of: p.t) { _, t in
            // Test before mutating: any write to the observed viewport redraws every lane.
            let v = model.ui.viewport
            guard p.isPlaying, t < v.start || t > v.end else { return }
            var nv = v
            nv.follow(t)
            model.ui.viewport = nv
        }
    }
}
