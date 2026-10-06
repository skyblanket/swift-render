import SwiftUI
import SwiftRenderKit

// MARK: - Region tool   // S6
//
// Armed with R (or ⌥-drag any time): drag → normalized `ReviewRegion` rect, click →
// point pin. Shell: draws the rubber band and opens the composer draft at the
// playhead; S6 adds the composer popover anchored to the rect (Post ⌘↩ / Post & Ask
// Claude ⌘⇧↩), the live scene-point readout, and pin editing.

struct RegionTool: View {
    @Bindable var model: ProjectModel
    var canvas: CGRect
    @State private var dragStart: CGPoint?
    @State private var dragNow: CGPoint?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle())
            if let a = dragStart, let b = dragNow {
                let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                Rectangle()
                    .strokeBorder(StudioStyle.accent, lineWidth: 1.5)
                    .background(StudioStyle.accent.opacity(0.12))
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
                Text(RegionMath.describe(RegionMath.normalize(r, in: canvas), sceneSize: sceneSize))
                    .font(StudioStyle.monoSmall)
                    .padding(4)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                    .offset(x: r.minX, y: max(0, r.minY - 22))
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if dragStart == nil { dragStart = v.startLocation }
                    dragNow = v.location
                }
                .onEnded { v in
                    let r = CGRect(x: min(v.startLocation.x, v.location.x), y: min(v.startLocation.y, v.location.y),
                                   width: abs(v.location.x - v.startLocation.x), height: abs(v.location.y - v.startLocation.y))
                    let isClick = r.width < RegionMath.clickSlop && r.height < RegionMath.clickSlop
                    let region = isClick ? RegionMath.point(v.startLocation, in: canvas) : RegionMath.normalize(r, in: canvas)
                    dragStart = nil; dragNow = nil
                    model.ui.regionArmed = false
                    model.playback.pause()
                    model.review.beginComment(t: model.playback.t, end: model.playback.inOut?.upperBound, region: region)
                    model.ui.inspectorTab = .comments
                    model.ui.showInspector = true
                }
        )
        .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
    }

    private var sceneSize: CGSize {
        CGSize(width: model.info?.width ?? 1920, height: model.info?.height ?? 1080)
    }
}
