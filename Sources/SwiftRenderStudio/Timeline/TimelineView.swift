import AppKit
import SwiftUI
import SwiftRenderKit

// MARK: - Timeline
//
// Header column + lanes column. The ruler is pinned on top, lanes scroll vertically
// when they overflow, a thin scroller sits at the bottom. Every lane is its own view
// and Canvas, reading only what it draws (a comment edit never redraws the
// waveform); the playhead is the only 60 Hz view. One drag gesture and one hover
// handler cover the whole column and resolve points through `TimelineLayout`.

struct TimelineView: View {
    @Bindable var model: ProjectModel
    @State private var state = TimelineState()
    static let headerWidth: CGFloat = 116
    /// Air before 0:00, so the first label and the playhead's cap are never cut off.
    static let gutter: CGFloat = 10

    var body: some View {
        let layout = TimelineLayout(info: model.info)
        HStack(spacing: 0) {
            TimelineHeaderColumn(model: model, state: state, layout: layout)
                .frame(width: Self.headerWidth)
                // Not into the safe area: it would extend under the sidebar's edge as a seam.
                .background(StudioStyle.chromeAlt, ignoresSafeAreaEdges: [])
            StudioStyle.hairline.frame(width: 1)
            GeometryReader { geo in
                let lanes = CGSize(width: max(1, geo.size.width - Self.gutter), height: geo.size.height)
                ZStack(alignment: .topLeading) {
                    StudioStyle.chromeAlt
                        .frame(width: geo.size.width, height: TimelineLayout.rulerHeight)
                    TimelineLanesColumn(model: model, state: state, layout: layout, size: lanes)
                        .offset(x: Self.gutter)
                    PlayheadOverlay(model: model, inset: Self.gutter,
                                    notesY: layout.columnY(.notes, scrollY: state.scrollY))
                        .frame(width: geo.size.width, height: max(0, geo.size.height - TimelineLayout.scrollerHeight))
                }
            }
            .clipped()
        }
        .background(StudioStyle.chrome)
        .overlay(ScrollCatcher(
            lanesX: Self.headerWidth + 1 + Self.gutter,
            onPan: { dx in model.ui.viewport.pan(by: dx) },
            onZoom: { f, x in model.ui.viewport.zoom(by: f, around: x) },
            onScrollY: { dy in
                state.scrollY = min(layout.maxScroll(lanesHeight: state.lanesHeight), max(0, state.scrollY + dy))
            },
            canScrollY: { layout.maxScroll(lanesHeight: state.lanesHeight) > 0 }))
        .onChange(of: model.info?.name) { _, _ in state.scrollY = 0 }
        .onReceive(NotificationCenter.default.publisher(for: TimelineSnapshot.hoverNotification)) { n in
            guard let p = n.object as? CGPoint else { return }
            TimelineInput(model: model, state: state, layout: layout, lanesHeight: state.lanesHeight).hover(at: p)
        }
    }
}

/// Ruler, lanes, scroller and the overlays that span them.
struct TimelineLanesColumn: View {
    let model: ProjectModel
    let state: TimelineState
    let layout: TimelineLayout
    let size: CGSize

    var body: some View {
        let lanesHeight = max(0, size.height - TimelineLayout.rulerHeight - TimelineLayout.scrollerHeight)
        let input = TimelineInput(model: model, state: state, layout: layout, lanesHeight: lanesHeight)
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                LaneView(key: .ruler, model: model, state: state)
                    .frame(height: TimelineLayout.rulerHeight)
                    .background(StudioStyle.chromeAlt)
                    .overlay(alignment: .bottom) { StudioStyle.hairline.frame(height: 1) }
                Color.clear
                    .frame(height: lanesHeight)
                    .overlay(alignment: .top) {
                        VStack(spacing: 0) {
                            ForEach(layout.slots, id: \.key) { slot in
                                LaneView(key: slot.key, model: model, state: state)
                                    .frame(height: slot.height)
                                    .overlay(alignment: .bottom) { StudioStyle.hairline.opacity(0.6).frame(height: 1) }
                            }
                        }
                        .offset(y: -state.scrollY)
                    }
                    .overlay(alignment: .bottom) {
                        // More lanes below: scroll vertically to reach them.
                        if state.scrollY < layout.maxScroll(lanesHeight: lanesHeight) - 0.5 {
                            LinearGradient(colors: [.clear, StudioStyle.chrome], startPoint: .top, endPoint: .bottom)
                                .frame(height: 12)
                                .allowsHitTesting(false)
                        }
                    }
                    .clipped()
                TimelineScroller(model: model)
                    .frame(height: TimelineLayout.scrollerHeight)
            }
            InOutShade(model: model)
                .frame(height: lanesHeight)
                .offset(y: TimelineLayout.rulerHeight)
            TimelineHoverOverlay(model: model, state: state, layout: layout, lanesHeight: lanesHeight)
                .frame(height: TimelineLayout.rulerHeight + lanesHeight)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { input.changed(start: $0.startLocation, location: $0.location) }
            .onEnded { input.ended(start: $0.startLocation, location: $0.location) })
        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { input.doubleClick(at: $0.location) })
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let p): input.hover(at: p)
            case .ended: input.hoverEnded()
            }
        }
        .contextMenu { TimelineContextMenu(model: model, state: state) }
        .onAppear { resize(lanesHeight) }
        .onChange(of: size) { _, _ in resize(lanesHeight) }
        .onChange(of: layout.contentHeight) { _, _ in resize(lanesHeight) }
    }

    private func resize(_ lanesHeight: CGFloat) {
        state.lanesHeight = lanesHeight
        let maxY = layout.maxScroll(lanesHeight: lanesHeight)
        if state.scrollY > maxY { state.scrollY = maxY }
        var nv = model.ui.viewport
        nv.resize(width: size.width)
        if nv != model.ui.viewport { model.ui.viewport = nv }
    }
}

// MARK: - Lane views

/// Builds each lane's renderer from the model. Called from lane bodies (so each
/// lane observes only what it draws) and from input handlers (not observed).
@MainActor
enum TimelineLanes {
    static func renderer(_ key: LaneKey, _ m: ProjectModel, _ s: TimelineState) -> any LaneRenderer {
        switch key {
        case .ruler: return ruler(m)
        case .clips: return clips(m)
        case .captions: return CaptionsLane(captions: m.info?.captions ?? [])
        case .score(let title): return ScoreLanes.renderer(title: title, events: m.info?.events ?? [])
        case .audio: return waveform(m)
        case .notes: return CommentsLane(comments: m.review.comments, selection: m.review.selection, preview: s.retime)
        }
    }

    static func ruler(_ m: ProjectModel) -> RulerLane {
        RulerLane(cached: m.playback.cachedRanges, inOut: m.playback.inOut, duration: m.playback.duration)
    }

    static func clips(_ m: ProjectModel) -> ClipsLane {
        let clips = m.info?.clips ?? []
        return ClipsLane(clips: clips, selectedID: m.ui.selectedClipID,
                         names: ClipLabels.shared.labels(for: clips, generation: m.build.generation))
    }

    static func waveform(_ m: ProjectModel) -> WaveformLane {
        let info = m.info
        let summary = m.scenes.first { $0.name == info?.name }
        let overview = info?.audioPath.flatMap { AudioOverviewCache.shared.overview($0) }
        let pending = (summary?.hasSoundtrack ?? false) && (info?.loudness.isEmpty ?? true) && overview == nil
        return WaveformLane(loudness: info?.loudness ?? [], rate: info?.loudnessRate ?? 50,
                            overview: overview, pending: pending)
    }
}

struct LaneView: View {
    let key: LaneKey
    let model: ProjectModel
    let state: TimelineState

    var body: some View {
        let r = TimelineLanes.renderer(key, model, state)
        let v = model.ui.viewport
        Canvas(opaque: false, rendersAsynchronously: key == .audio) { ctx, size in
            r.draw(in: &ctx, size: size, viewport: v)
        }
    }
}

// MARK: - Input

/// Pointer handling for the lanes column: scrub, in/out flags, comment retiming,
/// click to select or seek, double-click to open source, hover cards.
@MainActor
struct TimelineInput {
    let model: ProjectModel
    let state: TimelineState
    let layout: TimelineLayout
    let lanesHeight: CGFloat

    static let clickSlop: CGFloat = 3

    private var viewport: TimelineViewport { model.ui.viewport }

    func zone(_ p: CGPoint) -> TimelineLayout.Zone {
        layout.zone(at: p, lanesHeight: lanesHeight, scrollY: state.scrollY)
    }

    /// The lane and item under a lanes-column point.
    func hit(_ p: CGPoint) -> (key: LaneKey?, hit: LaneHit?) {
        switch zone(p) {
        case .ruler(let q): return (.ruler, TimelineLanes.ruler(model).hit(q, viewport: viewport))
        case .lane(let k, let q): return (k, TimelineLanes.renderer(k, model, state).hit(q, viewport: viewport))
        case .empty, .scroller: return (nil, nil)
        }
    }

    func changed(start: CGPoint, location: CGPoint) {
        if state.drag == nil { begin(start) }
        if !state.dragMoved, hypot(location.x - start.x, location.y - start.y) > Self.clickSlop { state.dragMoved = true }
        let v = viewport
        switch state.drag {
        case .scrub?:
            scrub(location.x, precise: false)
        case .inOut(let isIn)?:
            guard let io = model.playback.inOut else { return }
            let t = v.snap(v.t(min(max(0, location.x), v.width)))
            model.playback.setInOut(isIn ? min(t, io.upperBound)...io.upperBound : io.lowerBound...max(t, io.lowerBound))
        case .retime(let h, let t0, let end0)?:
            guard state.dragMoved else { return }
            let r = RetimeMath.apply(h.part, t: t0, end: end0, delta: v.t(location.x) - v.t(start.x),
                                     duration: model.playback.duration, fps: v.fps)
            let p = RetimePreview(id: h.id, t: r.t, end: r.end)
            if state.retime != p { state.retime = p }
        case .press?:
            // Clips aren't movable (their times are code): dragging off one scrubs.
            if state.dragMoved {
                state.drag = .scrub
                model.playback.pause()
                scrub(location.x, precise: false)
            }
        case nil:
            break
        }
    }

    private func begin(_ p: CGPoint) {
        state.dragMoved = false
        state.hover = nil
        switch zone(p) {
        case .ruler(let q):
            if let h = TimelineLanes.ruler(model).hit(q, viewport: viewport), h.kind == .inOut {
                state.drag = .inOut(isIn: h.id == "in")
            } else {
                state.drag = .scrub
                model.playback.pause()
                scrub(p.x, precise: false)
            }
        case .lane(.notes, let q):
            if let h = TimelineLanes.renderer(.notes, model, state).hit(q, viewport: viewport),
               let c = model.review.comments.first(where: { $0.id == h.id }) {
                state.drag = .retime(h, t: c.t, end: c.end)
            } else {
                state.drag = .press(.notes, nil)
            }
        case .lane(let k, let q):
            state.drag = .press(k, TimelineLanes.renderer(k, model, state).hit(q, viewport: viewport))
        case .empty:
            state.drag = .press(nil, nil)
        case .scroller:
            state.drag = nil
        }
    }

    func ended(start: CGPoint, location: CGPoint) {
        defer { state.drag = nil; state.retime = nil; state.dragMoved = false }
        switch state.drag {
        case .scrub?:
            scrub(location.x, precise: true)
        case .retime(let h, _, _)?:
            if state.dragMoved, let r = state.retime {
                do {
                    try model.review.retimeComment(h.id, t: r.t, end: r.end)
                    model.review.selection = h.id
                } catch {
                    model.ui.toast = "Couldn't move the comment. \(error)"
                }
            } else {
                selectComment(h.id, at: h.start)
            }
        case .press(let key, let h)?:
            click(key, h, x: location.x)
        case .inOut?, nil:
            break
        }
    }

    private func click(_ key: LaneKey?, _ h: LaneHit?, x: CGFloat) {
        switch h?.kind {
        case .clip?:
            model.ui.selectedClipID = model.ui.selectedClipID == h!.id ? nil : h!.id
        case .event?, .caption?, .silence?:
            model.playback.seek(h!.start, precise: true)
        default:
            model.playback.seek(viewport.snap(viewport.t(x)), precise: true)
        }
    }

    func doubleClick(at p: CGPoint) {
        let (key, h) = hit(p)
        if key == .notes, h == nil {
            // Double-click an empty spot in NOTES: a new comment there.
            let t = min(max(0, viewport.snap(viewport.t(p.x))), model.playback.duration)
            model.playback.pause()
            model.playback.seek(t, precise: true)
            model.review.beginComment(t: t)
            model.review.threadOpen = false
            model.ui.inspectorTab = .comments
            model.ui.showInspector = true
            return
        }
        guard let h else { return }
        switch h.kind {
        case .clip:
            guard let c = model.info?.clips.first(where: { $0.id == h.id }) else { return }
            model.ui.selectedClipID = c.id
            if let src = c.source { SourceOpener.open(src) } else { model.ui.toast = "This clip has no source line to open" }
        case .comment:
            selectComment(h.id, at: h.start)
        default:
            break
        }
    }

    func selectComment(_ id: String, at t: Double) {
        model.review.open(id)
        model.ui.inspectorTab = .comments
        model.ui.showInspector = true
        model.playback.seek(t, precise: true)
    }

    /// Seek to the pointer, kept inside the visible range (no runaway auto-scroll).
    private func scrub(_ x: CGFloat, precise: Bool) {
        let v = viewport
        let t = v.t(min(max(0, x), v.width))
        model.playback.seek(precise ? v.snap(t) : t, precise: precise)
    }

    func hover(at p: CGPoint) {
        guard state.drag == nil else { return }
        if case .scroller = zone(p) { hoverEnded(); return }
        let (key, h) = hit(p)
        let next = TimelineState.Hover(point: p, key: key, hit: h)
        if state.hover != next { state.hover = next }
        let resize = h?.kind == .inOut || (h?.kind == .comment && h?.part != .body)
        if resize { NSCursor.resizeLeftRight.set(); state.cursorSet = true }
        else if state.cursorSet { NSCursor.arrow.set(); state.cursorSet = false }
    }

    func hoverEnded() {
        if state.hover != nil { state.hover = nil }
        if state.cursorSet { NSCursor.arrow.set(); state.cursorSet = false }
    }
}


// MARK: - Context menu
//
// Whatever is under the pointer: a clip, a comment marker (the same menu as its list row
// and pin), a score event or caption, or a bare spot on the ruler or a lane (a time).

struct TimelineContextMenu: View {
    let model: ProjectModel
    let state: TimelineState
    @AppStorage(TimelinePrefs.follow) private var follow = true

    var body: some View {
        let hover = state.hover
        let h = hover?.hit
        // A comment marker's Delete Comment… stays last, after the timeline's own commands.
        let commentMenu = h.flatMap { h in
            h.kind == .comment ? model.review.comments.first(where: { $0.id == h.id }) : nil
        }.map { ContextMenus.comment($0, model: model).splitDestructive }
        if let h, h.kind == .clip, let c = model.info?.clips.first(where: { $0.id == h.id }) {
            StudioMenuContent(entries: ContextMenus.clip(c, model: model))
            Divider()
        } else if let commentMenu {
            StudioMenuContent(entries: commentMenu.head)
            Divider()
        } else if let h, [.event, .caption, .silence].contains(h.kind) {
            Button("Comment on This Range…") { ContextMenus.comment(model, t: h.start, end: h.end > h.start ? h.end : nil) }
            Button("Select Range") { model.playback.setInOut(h.start...max(h.start, h.end)) }
            Button("Copy Timecode") {
                model.edits.copy(h.end > h.start ? "\(StudioTime.precise(h.start))–\(StudioTime.precise(h.end))"
                                                 : StudioTime.precise(h.start))
            }
            Divider()
        } else if let p = hover?.point, let t = Self.time(at: p.x, model: model) {
            StudioMenuContent(entries: ContextMenus.time(t, model: model))
            Divider()
        }
        Button("Zoom to Fit") { model.perform(.timelineZoomFit) }
        Toggle("Follow Playhead", isOn: $follow)
        if let commentMenu, !commentMenu.destructive.isEmpty {
            Divider()
            StudioMenuContent(entries: commentMenu.destructive)
        }
    }

    /// The frame-snapped time under a lanes-column x, inside the scene.
    static func time(at x: CGFloat, model: ProjectModel) -> Double? {
        let v = model.ui.viewport
        guard model.playback.duration > 0, x >= 0, x <= v.width else { return nil }
        return min(max(0, v.snap(v.t(x))), model.playback.duration)
    }
}
