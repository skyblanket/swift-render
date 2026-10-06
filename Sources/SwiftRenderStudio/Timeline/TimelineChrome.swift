import SwiftUI
import SwiftRenderKit

// MARK: - Timeline chrome
//
// Lane headers (scrolling with the lanes; counts live in their tooltips), the Fit and
// follow-playhead controls above them, the zoom slider below, the in/out shade over the
// lanes, the hover layer (skimmer line, time chip, highlight, card) and the overview
// scroller. Each is its own view so it observes only its inputs.

struct TimelineHeaderColumn: View {
    let model: ProjectModel
    let state: TimelineState
    let layout: TimelineLayout

    var body: some View {
        VStack(spacing: 0) {
            TimelineZoomControls(model: model)
                .frame(height: TimelineLayout.rulerHeight)
                .overlay(alignment: .bottom) { StudioStyle.hairline.frame(height: 1) }
            // An overlay never sizes its parent: overflowing headers can't push the column taller.
            Color.clear
                .frame(maxHeight: .infinity)
                .overlay(alignment: .top) {
                    VStack(spacing: 0) {
                        ForEach(layout.slots, id: \.key) { slot in
                            LaneHeader(slot: slot, model: model)
                                .frame(height: slot.height)
                                .overlay(alignment: .bottom) { StudioStyle.hairline.opacity(0.6).frame(height: 1) }
                        }
                    }
                    .offset(y: -state.scrollY)
                }
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
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lane.rowLabels.enumerated()), id: \.offset) { i, l in
                    HStack(spacing: StudioStyle.Space.xs) {
                        if i == 0 { Text(slot.title).font(StudioStyle.Fonts.sectionLabel).foregroundStyle(.secondary) }
                        Spacer(minLength: 0)
                        if !l.isEmpty { Text(l).font(StudioStyle.Fonts.footnote).foregroundStyle(.tertiary) }
                    }
                    .frame(height: ClipsLane.rowHeight)
                }
                if lane.rowLabels.isEmpty {
                    Text(slot.title).font(StudioStyle.Fonts.sectionLabel).foregroundStyle(.secondary)
                        .frame(height: ClipsLane.rowHeight)
                }
            }
            .padding(.horizontal, StudioStyle.Space.m)
            .padding(.top, ClipsLane.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .help(model.info?.clips.isEmpty ?? true
                  ? "One continuous shot. Wrap shots in Timeline { Clip(…) } to see them here."
                  : "\(model.info?.clips.count ?? 0) clips")
        case .captions:
            title(slot.title).help("\(model.info?.captions.count ?? 0) captions")
        case .score(let name):
            let lane = ScoreLanes.renderer(title: name, events: model.info?.events ?? [])
            let warn = lane.warnings
            HStack(spacing: StudioStyle.Space.xs) {
                title(slot.title)
                if warn > 0 {
                    Image(systemName: StudioStyle.Symbol.warning).font(StudioStyle.Fonts.footnote)
                        .foregroundStyle(StudioStyle.warning)
                        .padding(.trailing, StudioStyle.Space.m)
                }
            }
            .help(warn > 0 ? ScoreLane.houseRuleNote : "\(lane.events.count) \(name.lowercased()) events")
        case .audio:
            let lane = TimelineLanes.waveform(model)
            HStack(spacing: StudioStyle.Space.xs) {
                title(slot.title)
                if lane.pending { ProgressView().controlSize(.mini).padding(.trailing, StudioStyle.Space.m) }
            }
            .help(lane.pending ? "Mixing the music…" : silenceHelp)
        case .notes:
            let open = model.review.count(segment: .open)
            title(slot.title).help(open > 0 ? "\(open) open" : "Double-click the lane to comment there")
        case .ruler:
            EmptyView()
        }
    }

    private var silenceHelp: String {
        let n = model.info?.audioPath.flatMap { AudioOverviewCache.shared.overviews[$0]?.silences.count } ?? 0
        return n > 0 ? "\(n) quiet stretch\(n == 1 ? "" : "es")" : "The film's sound"
    }

    private func title(_ t: String) -> some View {
        HStack {
            Text(t)
                .font(StudioStyle.Fonts.sectionLabel)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, StudioStyle.Space.m)
        .frame(maxHeight: .infinity)
    }
}

/// Above the headers: Zoom to Fit and Follow Playhead.
struct TimelineZoomControls: View {
    let model: ProjectModel
    @AppStorage(TimelinePrefs.follow) private var follow = true

    var body: some View {
        HStack(spacing: StudioStyle.Space.s) {
            // Always a normal button in label color (a disabled "Fit" read as broken).
            Button { model.perform(.timelineZoomFit) } label: {
                Text("Fit").foregroundStyle(.primary)
            }
            .help(model.ui.viewport.isFit ? "The whole film fits (⇧Z)" : "Zoom to Fit (⇧Z)")
            Spacer(minLength: 0)
            Toggle(isOn: $follow) { Image(systemName: "arrow.right.to.line") }
                .toggleStyle(.button)
                .help(follow ? "Following the playhead. Click to stop." : "Follow the playhead")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .font(StudioStyle.Fonts.subheadline)
        .padding(.horizontal, StudioStyle.Space.s)
    }
}

/// Below the headers: the zoom slider (fit … frame level), native, with magnifier ends.
struct TimelineFooterControls: View {
    let model: ProjectModel

    var body: some View {
        Slider(value: Binding(get: { model.ui.viewport.zoomLevel }, set: { level in
            var nv = model.ui.viewport
            let px = nv.x(model.playback.t)
            let anchor = px >= 0 && px <= nv.width ? px : nv.width / 2
            nv.setZoomLevel(level, around: anchor)
            model.ui.viewport = nv
        }), in: 0...1) {
            Text("Zoom")
        } minimumValueLabel: {
            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
        } maximumValueLabel: {
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
        }
        .labelsHidden()
        .controlSize(.mini)
        .padding(.horizontal, StudioStyle.Space.s)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .top) { StudioStyle.hairline.frame(height: 1) }
        .help("Timeline zoom (⌘= and ⌘−, ⌥-scroll or pinch)")
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
            let shade = GraphicsContext.Shading.color(StudioStyle.pictureScrim.opacity(0.5))
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
                ctx.stroke(line, with: .style(.tertiary), lineWidth: 1)
                if let rect = h.hit?.rect, let key = h.key, let y0 = key == .ruler ? 0 : layout.columnY(key, scrollY: scrollY) {
                    var c = ctx
                    c.clip(to: Path(CGRect(x: 0, y: TimelineLayout.rulerHeight, width: size.width, height: lanesHeight)))
                    let r = rect.offsetBy(dx: 0, dy: y0).insetBy(dx: -1, dy: -1)
                    c.stroke(Path(roundedRect: r, cornerRadius: StudioStyle.Radius.small, style: .continuous),
                             with: .style(.secondary), lineWidth: 1)
                }
                // Time chip in the ruler.
                let major = v.tickSpacing().major
                let at = v.snap(v.t(x))
                let text = major < 0.25 ? TimelineViewport.label(at, major: major, fps: v.fps) : StudioTime.precise(at)
                let label = ctx.resolve(Text(text).font(StudioStyle.Fonts.footnote.weight(.medium)).monospacedDigit()
                    .foregroundStyle(.primary))
                let w = label.measure(in: CGSize(width: 200, height: 20)).width + 10
                let chip = CGRect(x: min(max(0, x - w / 2), size.width - w), y: 1, width: w, height: 15)
                ctx.fill(Path(roundedRect: chip, cornerRadius: StudioStyle.Radius.small, style: .continuous), with: .color(StudioStyle.raised))
                ctx.stroke(Path(roundedRect: chip, cornerRadius: StudioStyle.Radius.small, style: .continuous), with: .color(StudioStyle.hairline))
                ctx.draw(label, at: CGPoint(x: chip.midX, y: chip.midY))
            }
            if let r = retime {
                HoverCard(title: "Move", detail: LaneDraw.range(r.t, r.end ?? r.t)
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
                .font(StudioStyle.Fonts.calloutEmphasis)
                .foregroundStyle(.primary)
                .lineLimit(2)
            if let detail {
                Text(detail)
                    .font(StudioStyle.Fonts.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(4)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 10)
        .padding(.vertical, StudioStyle.Space.s)
        .frame(width: Self.width, alignment: .leading)
        .studioCard(cornerRadius: StudioStyle.Radius.medium)
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
        let marks = model.review.comments.map { ($0.t, CommentState($0) == .readyForReview) }
        GeometryReader { geo in
            let w = geo.size.width
            let scale = Double(w) / max(0.001, v.duration)
            Canvas { ctx, size in
                let mid = size.height / 2
                ctx.fill(Path(roundedRect: CGRect(x: 2, y: mid - 2, width: size.width - 4, height: 4), cornerRadius: 2),
                         with: .color(StudioStyle.well))
                if let io {
                    ctx.fill(Path(CGRect(x: io.lowerBound * scale, y: mid - 2, width: max(1, (io.upperBound - io.lowerBound) * scale),
                                         height: 4)), with: .color(StudioStyle.accent.opacity(0.45)))
                }
                for (t, review) in marks {
                    ctx.fill(Path(roundedRect: CGRect(x: t * scale - 1, y: mid - 4, width: 2, height: 8), cornerRadius: 1),
                             with: .color(review ? StudioStyle.accent : StudioStyle.discFill.opacity(0.8)))
                }
                let thumb = CGRect(x: v.start * scale, y: 3, width: max(14, v.span * scale), height: size.height - 6)
                let shape = Path(roundedRect: thumb, cornerRadius: (size.height - 6) / 2, style: .continuous)
                ctx.fill(shape, with: .color(StudioStyle.well))
                ctx.stroke(shape, with: .color(StudioStyle.hairline), lineWidth: 1)
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
        .overlay(alignment: .top) { StudioStyle.hairline.frame(height: 1) }
    }
}
