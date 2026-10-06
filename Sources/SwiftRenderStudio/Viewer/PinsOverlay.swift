import SwiftUI
import SwiftRenderKit

// MARK: - Pins   // S6
//
// Comments within ±0.25 s of the playhead (`PlaybackEngine.visibleCommentIDs`,
// republished only when the set changes), numbered in scene order, colored by
// status. Shell: rect/point drawing + click-to-select; S6 adds hover text and editing.

struct PinsOverlay: View {
    @Bindable var model: ProjectModel
    var canvas: CGRect

    var body: some View {
        let visible = model.playback.visibleCommentIDs
        let ordered = model.review.comments.sorted { $0.t < $1.t }
        ZStack(alignment: .topLeading) {
            ForEach(Array(ordered.enumerated()), id: \.element.id) { i, c in
                if visible.contains(c.id), let region = c.region {
                    pin(c, number: i + 1, region: region)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func pin(_ c: ReviewComment, number: Int, region: ReviewRegion) -> some View {
        let r = RegionMath.rect(region, in: canvas)
        let color = StudioStyle.color(c.status)
        let selected = model.review.selection == c.id
        if !RegionMath.isPoint(region) {
            Rectangle()
                .strokeBorder(color, lineWidth: selected ? 2.5 : 1.5)
                .background(color.opacity(selected ? 0.14 : 0.06))
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
                .allowsHitTesting(false)
        }
        Text("\(number)")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.black)
            .frame(width: 18, height: 18)
            .background(color, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(selected ? 0.9 : 0.4), lineWidth: 1))
            .offset(x: (RegionMath.isPoint(region) ? r.minX : r.maxX) - 9, y: r.minY - 9)
            .onTapGesture { model.review.selection = c.id; model.ui.inspectorTab = .comments }
            .help(c.body)
    }
}
