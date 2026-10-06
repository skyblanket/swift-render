import SwiftUI
import SwiftRenderKit

// MARK: - Pins
//
// Comments within ±0.25 s of the playhead (`PlaybackEngine.visibleCommentIDs`,
// republished only when the set changes), numbered in scene order, colored by status,
// agent comments ringed violet with a sparkle. Hover a pin for its text; click selects
// the thread; the selected comment shows a caption, and its rect can be dragged to a
// new spot (written on release). A/B compare draws over them.

struct PinsOverlay: View {
    @Bindable var model: ProjectModel
    var canvas: CGRect
    @State private var hovered: String?
    @State private var dragOffset: CGSize = .zero
    @State private var draggingID: String?

    var body: some View {
        let visible = model.playback.visibleCommentIDs
        let numbers = ReviewController.numbering(model.review.comments)
        let shown = model.review.comments
            .filter { visible.contains($0.id) && $0.region != nil }
            .sorted { (numbers[$0.id] ?? 0) < (numbers[$1.id] ?? 0) }
        ZStack(alignment: .topLeading) {
            ForEach(shown) { c in
                pin(c, number: numbers[c.id], region: c.region!)
            }
            if let id = hovered ?? model.review.selection, let c = shown.first(where: { $0.id == id }) {
                caption(c, number: numbers[c.id], expanded: hovered == id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func pin(_ c: ReviewComment, number: Int?, region: ReviewRegion) -> some View {
        let base = RegionMath.rect(region, in: canvas)
        let r = draggingID == c.id ? base.offsetBy(dx: dragOffset.width, dy: dragOffset.height) : base
        let agent = c.author.kind == .agent
        let color = agent ? ReviewStyle.agent : StudioStyle.color(c.status)
        let selected = model.review.selection == c.id
        let isPoint = RegionMath.isPoint(region)
        if !isPoint {
            Rectangle()
                .strokeBorder(color, style: StrokeStyle(lineWidth: selected ? 2 : 1.25, dash: c.status.isActive ? [] : [4, 3]))
                .background(color.opacity(selected ? 0.12 : 0.05))
                .frame(width: max(1, r.width), height: max(1, r.height))
                .offset(x: r.minX, y: r.minY)
                .allowsHitTesting(selected)
                .gesture(selected ? moveGesture(c, region: region) : nil)
                .help(selected ? "Drag to move this note's region" : "")
        }
        CommentBadge(number: number, status: c.status, agent: agent, selected: selected, size: selected ? 20 : 18)
            .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
            .offset(x: (isPoint ? r.minX : r.maxX) - 10, y: r.minY - 10)
            .onHover { inside in hovered = inside ? c.id : (hovered == c.id ? nil : hovered) }
            .onTapGesture {
                model.review.selection = c.id
                model.ui.inspectorTab = .comments
                model.ui.showInspector = true
            }
    }

    /// Text beside the selected (or hovered) pin: one line, or the whole note on hover.
    private func caption(_ c: ReviewComment, number: Int?, expanded: Bool) -> some View {
        let r = RegionMath.rect(c.region!, in: canvas)
        let agent = c.author.kind == .agent
        let width: CGFloat = expanded ? 260 : 220
        let x = min(max(canvas.minX + 4, (RegionMath.isPoint(c.region!) ? r.minX : r.maxX) + 14), canvas.maxX - width - 4)
        let below = r.minY - 10 < canvas.minY + 40
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if agent { Image(systemName: "sparkles").foregroundStyle(ReviewStyle.agent) }
                Text(c.author.name).font(.system(size: 10, weight: .semibold))
                Text(c.timecode).font(StudioStyle.monoSmall).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(ReviewStyle.shortTitle(c.status)).font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(StudioStyle.color(c.status))
            }
            Text(c.body).font(.system(size: 11)).lineLimit(expanded ? 6 : 1)
            if expanded, let last = c.replies.last {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "arrowshape.turn.up.left").font(.system(size: 8))
                    Text("\(last.author.name): \(last.body)").lineLimit(2)
                }
                .font(.system(size: 10))
                .foregroundStyle(last.author.kind == .agent ? ReviewStyle.agent : .secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(width: width, alignment: .leading)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder((agent ? ReviewStyle.agent : .white).opacity(0.18)))
        .offset(x: x, y: below ? r.minY + 14 : r.minY - 10)
        .allowsHitTesting(false)
    }

    private func moveGesture(_ c: ReviewComment, region: ReviewRegion) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { g in draggingID = c.id; dragOffset = g.translation }
            .onEnded { g in
                let moved = Self.moved(region, by: g.translation, canvas: canvas)
                draggingID = nil; dragOffset = .zero
                if moved != region {
                    do { try model.review.moveRegion(c.id, to: moved) } catch { model.ui.toast = "\(error)" }
                }
            }
    }

    /// Region translated by a view-space drag, kept whole inside the frame.
    static func moved(_ r: ReviewRegion, by d: CGSize, canvas: CGRect) -> ReviewRegion {
        guard canvas.width > 0, canvas.height > 0 else { return r }
        let x = min(max(0, r.x + Double(d.width / canvas.width)), 1 - r.w)
        let y = min(max(0, r.y + Double(d.height / canvas.height)), 1 - r.h)
        return ReviewRegion(x: (x * 10_000).rounded() / 10_000, y: (y * 10_000).rounded() / 10_000, w: r.w, h: r.h)
    }
}
