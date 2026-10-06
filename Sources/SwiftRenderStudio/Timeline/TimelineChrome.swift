import SwiftUI
import SwiftRenderKit

// MARK: - Timeline chrome
//
// Lane headers (scrolling with the lanes), zoom and follow controls, the in/out
// shade over the lanes, the hover layer (skimmer line, time chip, highlight, card)
// and the overview scroller. Each is its own view so it observes only its inputs.

struct TimelineHeaderColumn: View {
    let model: ProjectModel
    let state: TimelineState
    let layout: TimelineLayout

    var body: some View {
        VStack(spacing: 0) {
            TimelineZoomControls(model: model)
                .frame(height: TimelineLayout.rulerHeight)
                .overlay(alignment: .bottom) { Color.black.opacity(0.5).frame(height: 1) }
            VStack(spacing: 0) {
                ForEach(layout.slots, id: \.key) { slot in
                    LaneHeader(slot: slot, model: model)
                        .frame(height: slot.height)
                        .overlay(alignment: .bottom) { StudioStyle.hairline.frame(height: 1) }
                }
            }
            .offset(y: -state.scrollY)
            .frame(maxHeight: .infinity, alignment: .top)
            .clipped()
            TimelineFooterControls(model: model)
                .frame(height: TimelineLayout.scrollerHeight)
        }
    }
}

struct LaneHeader: View {
    let slot: TimelineLayout.Slot
    let model: ProjectModel

    var body: some View {
        switch slot.key {
        case .clips:
            let lane = ClipsLane(clips: model.info?.clips ?? [])
            ZStack(alignment: .topLeading) {
                title(slot.title, detail: nil)
                    .frame(height: ClipsLane.rowHeight)
                    .offset(y: ClipsLane.inset)
                if lane.rows > 1 {
                    VStack(alignment: .trailing, spacing: 0) {
                        ForEach(Array(lane.rowLabels.enumerated()), id: \.offset) { _, l in
                            Text(l).font(.system(size: 8.5, weight: .medium)).foregroundStyle(.tertiary)
                                .frame(height: ClipsLane.rowHeight)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 8)
                    .offset(y: ClipsLane.inset)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .captions:
            title(slot.title, detail: "\(model.info?.captions.count ?? 0)")
        case .score(let name):
            let lane = ScoreLanes.renderer(title: name, events: model.info?.events ?? [])
            let warn = lane.warnings
            title(slot.title, detail: warn > 0 ? "⚠︎ \(warn)" : "\(lane.events.count)",
                  dot: lane.lanes.count == 1 ? StudioStyle.lane(lane.lanes.first!) : StudioStyle.lane("drums"),
                  warn: warn > 0)
                .help(warn > 0 ? ScoreLane.houseRuleNote : "")
        case .audio:
            let silences = model.info?.audioPath.flatMap { AudioOverviewCache.shared.overviews[$0]?.silences.count } ?? 0
            title(slot.title, detail: silences > 0 ? "\(silences) silent" : nil, dot: WaveformLane.wave)
        case .notes:
            let open = model.review.openCount
            title(slot.title, detail: open > 0 ? "\(open) open" : nil, dot: open > 0 ? StudioStyle.color(.open) : nil)
        case .ruler:
            EmptyView()
        }
    }

    private func title(_ t: String, detail: String?, dot: Color? = nil, warn: Bool = false) -> some View {
        HStack(spacing: 5) {
            if let dot { Circle().fill(dot).frame(width: 5, height: 5) }
            Text(t)
                .font(StudioStyle.laneLabel)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .layoutPriority(1)
            Spacer(minLength: 2)
            if let detail {
                Text(detail)
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(warn ? AnyShapeStyle(StudioStyle.warn) : AnyShapeStyle(.tertiary))
            }
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
    }
}

/// Zoom out / in / fit, and the visible span.
struct TimelineZoomControls: View {
    let model: ProjectModel

    var body: some View {
        let v = model.ui.viewport
        HStack(spacing: 1) {
            Button { model.perform(.timelineZoomOut) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out (⌘−, ⌥-scroll, pinch)")
            Button { model.perform(.timelineZoomIn) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in (⌘=, ⌥-scroll, pinch)")
            Button { model.perform(.timelineZoomFit) } label: {
                Text("FIT").font(.system(size: 8.5, weight: .bold))
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).stroke(.secondary.opacity(v.isFit ? 0.2 : 0.6)))
            }
            .disabled(v.isFit)
            .help("Zoom to fit (⇧Z)")
            Spacer(minLength: 2)
            Text(TimelineViewport.spanLabel(v.span, fps: v.fps))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .help("Visible span")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.leading, 7)
        .padding(.trailing, 8)
    }
}

/// Follow-playhead toggle and the zoom slider (fit … frame level).
struct TimelineFooterControls: View {
    let model: ProjectModel
    @AppStorage(TimelinePrefs.follow) private var follow = true

    var body: some View {
        HStack(spacing: 5) {
            Button { follow.toggle() } label: {
                Image(systemName: "arrow.right.to.line")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(follow ? AnyShapeStyle(StudioStyle.accent) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.borderless)
            .help(follow ? "Following the playhead (click to stop)" : "Follow the playhead")
            ZoomSlider(model: model)
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .top) { StudioStyle.hairline.frame(height: 1) }
    }
}

/// A thin custom slider: native sliders don't fit a 16 pt row.
struct ZoomSlider: View {
    let model: ProjectModel

    var body: some View {
        let v = model.ui.viewport
        GeometryReader { geo in
            let w = geo.size.width
            let k = CGFloat(v.zoomLevel)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12)).frame(height: 3)
                Capsule().fill(Color.white.opacity(0.35)).frame(width: max(3, k * w), height: 3)
                Circle().fill(Color(white: 0.85)).frame(width: 8, height: 8)
                    .offset(x: min(max(0, k * w - 4), w - 8))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                var nv = model.ui.viewport
                let px = nv.x(model.playback.t)
                let anchor = px >= 0 && px <= nv.width ? px : nv.width / 2
                nv.setZoomLevel(Double(g.location.x / max(1, w)), around: anchor)
                model.ui.viewport = nv
            })
        }
        .help("Timeline zoom")
    }
}

/// Dims the lanes outside in→out.
struct InOutShade: View {
    let model: ProjectModel

    var body: some View {
        let io = model.playback.inOut
        let v = model.ui.viewport
        Canvas { ctx, size in
            guard let io else { return }
            let x0 = v.x(io.lowerBound), x1 = v.x(io.upperBound)
            let shade = GraphicsContext.Shading.color(.black.opacity(0.28))
            if x0 > 0 { ctx.fill(Path(CGRect(x: 0, y: 0, width: min(size.width, x0), height: size.height)), with: shade) }
            if x1 < size.width { ctx.fill(Path(CGRect(x: max(0, x1), y: 0, width: size.width - max(0, x1), height: size.height)), with: shade) }
        }
        .allowsHitTesting(false)
    }
}

/// Skimmer line, time chip, item highlight and hover card. Redrawn on mouse move
/// only; the lanes underneath don't observe hover.
struct TimelineHoverOverlay: View {
    let model: ProjectModel
    let state: TimelineState
    let layout: TimelineLayout
    let lanesHeight: CGFloat

    var body: some View {
        let hover = state.hover
        let retime = state.retime
        let v = model.ui.viewport
        let scrollY = state.scrollY
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                guard let h = hover else { return }
                let x = h.point.x
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(line, with: .color(.white.opacity(0.22)), lineWidth: 1)
                if let rect = h.hit?.rect, let key = h.key, let y0 = key == .ruler ? 0 : layout.columnY(key, scrollY: scrollY) {
                    var c = ctx
                    c.clip(to: Path(CGRect(x: 0, y: TimelineLayout.rulerHeight, width: size.width, height: lanesHeight)))
                    let r = rect.offsetBy(dx: 0, dy: y0).insetBy(dx: -1, dy: -1)
                    c.fill(Path(roundedRect: r, cornerRadius: 3.5), with: .color(.white.opacity(0.07)))
                    c.stroke(Path(roundedRect: r, cornerRadius: 3.5), with: .color(.white.opacity(0.5)), lineWidth: 1)
                }
                // Time chip in the ruler.
                let label = ctx.resolve(Text(TimelineViewport.label(v.snap(v.t(x)), major: 0.01))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.black))
                let w = label.measure(in: CGSize(width: 200, height: 20)).width + 8
                let chip = CGRect(x: min(max(0, x - w / 2), size.width - w), y: 1, width: w, height: 13)
                ctx.fill(Path(roundedRect: chip, cornerRadius: 3), with: .color(Color(white: 0.86)))
                ctx.draw(label, at: CGPoint(x: chip.midX, y: chip.midY))
            }
            if let r = retime {
                HoverCard(title: "Retime", detail: LaneDraw.range(r.t, r.end ?? r.t)
                          + (r.end.map { " · " + LaneDraw.seconds($0 - r.t) } ?? ""))
                    .placed(at: hover?.point ?? CGPoint(x: v.x(r.t), y: TimelineLayout.rulerHeight + lanesHeight - 10))
            } else if let h = hover, let hit = h.hit, !hit.title.isEmpty || hit.detail != nil {
                HoverCard(title: hit.title, detail: hit.detail).placed(at: h.point)
            }
        }
        .allowsHitTesting(false)
    }
}

struct HoverCard: View {
    var title: String
    var detail: String?
    static let width: CGFloat = 248

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
            if let detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: Self.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.17).opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 8, y: 3)
    }

    /// Beside the pointer, flipped left/up near the right/bottom edges.
    func placed(at p: CGPoint) -> some View {
        GeometryReader { geo in
            let flipX = p.x + 14 + Self.width > geo.size.width
            let above = p.y > geo.size.height * 0.55
            self
                .frame(width: Self.width, height: max(1, above ? p.y - 10 : geo.size.height - p.y - 18),
                       alignment: above ? .bottom : .top)
                .offset(x: flipX ? max(0, p.x - 14 - Self.width) : p.x + 14, y: above ? 0 : p.y + 18)
        }
    }
}

/// Overview of the whole scene: thumb = visible range; drag the thumb to pan, click
/// elsewhere to center there, double-click to fit. Comment ticks and in/out for
/// orientation when zoomed in.
struct TimelineScroller: View {
    let model: ProjectModel
    @State private var grab: (start: Double, x: CGFloat)?

    var body: some View {
        let v = model.ui.viewport
        let io = model.playback.inOut
        let marks = model.review.comments.map { ($0.t, StudioStyle.color($0.status)) }
        GeometryReader { geo in
            let w = geo.size.width
            let scale = Double(w) / max(0.001, v.duration)
            Canvas { ctx, size in
                let mid = size.height / 2
                ctx.fill(Path(roundedRect: CGRect(x: 2, y: mid - 2, width: size.width - 4, height: 4), cornerRadius: 2),
                         with: .color(.white.opacity(0.06)))
                if let io {
                    ctx.fill(Path(CGRect(x: io.lowerBound * scale, y: mid - 2, width: max(1, (io.upperBound - io.lowerBound) * scale),
                                         height: 4)), with: .color(StudioStyle.accent.opacity(0.4)))
                }
                for (t, color) in marks {
                    ctx.fill(Path(CGRect(x: t * scale - 0.5, y: mid - 4, width: 1.5, height: 8)), with: .color(color.opacity(0.9)))
                }
                let thumb = CGRect(x: v.start * scale, y: 3, width: max(14, v.span * scale), height: size.height - 6)
                ctx.fill(Path(roundedRect: thumb, cornerRadius: 3.5), with: .color(.white.opacity(v.isFit ? 0.08 : 0.18)))
                ctx.stroke(Path(roundedRect: thumb, cornerRadius: 3.5), with: .color(.white.opacity(0.22)), lineWidth: 1)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    var nv = model.ui.viewport
                    if grab == nil {
                        let thumb = nv.start * scale...(nv.start + nv.span) * scale
                        if !thumb.contains(Double(g.startLocation.x)) {
                            nv.start = Double(g.startLocation.x) / scale - nv.span / 2      // jump: center here
                            nv.clamp()
                        }
                        grab = (nv.start, g.startLocation.x)
                    }
                    if let grab { nv.start = grab.start + Double(g.location.x - grab.x) / scale; nv.clamp() }
                    if nv != model.ui.viewport { model.ui.viewport = nv }
                }
                .onEnded { _ in grab = nil })
            .simultaneousGesture(TapGesture(count: 2).onEnded { model.perform(.timelineZoomFit) })
        }
        .background(Color.black.opacity(0.18))
    }
}
