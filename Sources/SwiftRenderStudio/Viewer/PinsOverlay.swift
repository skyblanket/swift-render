import SwiftUI
import SwiftRenderKit

// MARK: - Pins
//
// Comments within ±0.25 s of the playhead (`PlaybackEngine.visibleCommentIDs`,
// republished only when the set changes), each a numbered disc in the shared grammar
// (see `CommentDisc`). Hover a pin for its text; click opens the thread; the selected
// comment's rect can be dragged to a new spot (written on release), and it carries a small
// callout (author · time · status · first line). Compare draws over them.

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
            .filter { visible.contains($0.id) && $0.region != nil && Self.sameShape($0.canvas, as: model.info) }
            .sorted { (numbers[$0.id] ?? 0) < (numbers[$1.id] ?? 0) }
        ZStack(alignment: .topLeading) {
            ForEach(shown) { c in
                pin(c, number: numbers[c.id], region: c.region!)
            }
            if let id = hovered, let c = shown.first(where: { $0.id == id }) {
                caption(c)
            } else if model.review.draft == nil, draggingID == nil, let id = model.review.selection,
                      let c = shown.first(where: { $0.id == id }) {
                // The selected comment's callout: who, when, where it stands, and its first line.
                caption(c, compact: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A region is a fraction of the canvas it was drawn on: a box drawn at 9:16 marks a
    /// different area of a 16:9 frame, so it's only drawn (and draggable) on a canvas of the
    /// same shape. The thread still lists it.
    static func sameShape(_ canvas: ReviewCanvas?, as info: SceneInfo?) -> Bool {
        guard let c = canvas, c.width > 0, c.height > 0, let i = info, i.width > 0, i.height > 0 else { return true }
        return abs(Double(c.width) / Double(c.height) - Double(i.width) / Double(i.height)) < 0.01
    }

    @ViewBuilder
    private func pin(_ c: ReviewComment, number: Int?, region: ReviewRegion) -> some View {
        let base = RegionMath.rect(region, in: canvas)
        let r = draggingID == c.id ? base.offsetBy(dx: dragOffset.width, dy: dragOffset.height) : base
        let state = CommentState(c)
        let selected = model.review.selection == c.id
        let isPoint = RegionMath.isPoint(region)
        if !isPoint {
            let stroke = selected ? StudioStyle.accent : StudioStyle.onPicture.opacity(state.isActive ? 0.85 : 0.45)
            Rectangle()
                .strokeBorder(StudioStyle.pictureScrim, lineWidth: 3)
                .overlay(Rectangle().strokeBorder(stroke, style: StrokeStyle(lineWidth: 1.5, dash: state.isSettled ? [4, 3] : [])))
                .frame(width: max(1, r.width), height: max(1, r.height))
                .offset(x: r.minX, y: r.minY)
                .allowsHitTesting(selected)
                .gesture(selected ? moveGesture(c, region: region) : nil)
                .help(selected ? "Drag to move this spot" : "")
        }
        CommentDisc(number: number, state: state, selected: selected, size: 22)
            .shadow(color: StudioStyle.shadow.opacity(0.45), radius: 3, y: 1)
            .offset(x: (isPoint ? r.minX : r.maxX) - (selected ? 14 : 11), y: r.minY - (selected ? 14 : 11))
            .onHover { inside in hovered = inside ? c.id : (hovered == c.id ? nil : hovered) }
            .onTapGesture {
                model.review.open(c.id)
                model.ui.inspectorTab = .comments
                model.ui.showInspector = true
            }
    }

    /// The note beside a hovered pin; `compact` (the selected pin's callout) shows only
    /// the header and the first line.
    private func caption(_ c: ReviewComment, compact: Bool = false) -> some View {
        let r = RegionMath.rect(c.region!, in: canvas)
        let width: CGFloat = compact ? 240 : 260
        let x = min(max(canvas.minX + 4, (RegionMath.isPoint(c.region!) ? r.minX : r.maxX) + 16), canvas.maxX - width - 4)
        let below = r.minY - 10 < canvas.minY + 40
        return VStack(alignment: .leading, spacing: StudioStyle.Space.xs) {
            HStack(spacing: 6) {
                AuthorAvatar(author: c.author, size: 18)
                Text(ReviewStyle.displayName(c.author)).font(StudioStyle.Fonts.subheadline.weight(.semibold))
                Text(StudioTime.range(c.t, c.end)).font(StudioStyle.Fonts.subheadline).foregroundStyle(.secondary).monospacedDigit()
                Spacer(minLength: 0)
                StatusLabel(state: CommentState(c), font: StudioStyle.Fonts.footnote)
            }
            if compact {
                Text(c.body.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? c.body)
                    .font(StudioStyle.Fonts.callout).lineLimit(1).truncationMode(.tail)
            } else {
                Text(c.body).font(StudioStyle.Fonts.callout).lineLimit(5)
            }
            if !compact, let last = c.replies.last {
                Text("\(ReviewStyle.displayName(last.author)): \(last.body)")
                    .font(StudioStyle.Fonts.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(StudioStyle.Space.s)
        .frame(width: width, alignment: .leading)
        .studioCard(cornerRadius: StudioStyle.Radius.medium)
        .offset(x: x, y: below ? r.minY + 16 : r.minY - 10)
        .allowsHitTesting(false)
    }

    private func moveGesture(_ c: ReviewComment, region: ReviewRegion) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { g in draggingID = c.id; dragOffset = g.translation }
            .onEnded { g in
                let moved = Self.moved(region, by: g.translation, canvas: canvas)
                draggingID = nil; dragOffset = .zero
                if moved != region {
                    do { try model.review.moveRegion(c.id, to: moved) } catch { model.ui.toast = "Couldn't move it. \(error)" }
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
