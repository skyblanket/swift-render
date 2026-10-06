import SwiftUI
import SwiftRenderKit

// MARK: - Timeline
//
// Header column + lane column. Every lane is one Canvas drawn from the viewport
// ({start, pxPerSecond}); the playhead is a separate overlay; ScrollCatcher turns
// scroll/pinch into pan/zoom. Ruler drag scrubs (coalesced by PlaybackEngine).

struct TimelineView: View {
    @Bindable var model: ProjectModel
    static let headerWidth: CGFloat = 112

    var body: some View {
        let info = model.info
        let v = model.ui.viewport
        let ruler = RulerLane(cached: model.playback.cachedRanges, inOut: model.playback.inOut,
                              duration: model.playback.duration)
        let clips = ClipsLane(clips: info?.clips ?? [], selectedID: model.ui.selectedClipID)
        let captions = CaptionsLane(captions: info?.captions ?? [])
        let score = ScoreLanes.renderers(info?.events ?? [])
        let audio = WaveformLane(loudness: info?.loudness ?? [], rate: info?.loudnessRate ?? 50)
        let notes = CommentsLane(comments: model.review.comments, selection: model.review.selection)

        HStack(spacing: 0) {
            // Headers.
            VStack(alignment: .leading, spacing: 0) {
                TimelineZoomControls(model: model)
                    .frame(height: ruler.height)
                Divider()
                header(clips.title, height: clips.height, detail: clips.rows > 1 ? "\(clips.rows) rows" : nil)
                if !(info?.captions.isEmpty ?? true) { header(captions.title, height: captions.height) }
                ForEach(score, id: \.title) { header($0.title, height: $0.height, warn: $0.lanes.contains("fx")) }
                header(audio.title, height: audio.height)
                header(notes.title, height: notes.height, detail: model.review.openCount > 0 ? "\(model.review.openCount) open" : nil)
                Spacer(minLength: 0)
            }
            .frame(width: Self.headerWidth)
            .background(StudioStyle.laneAltBackground)

            Divider()

            // Lanes.
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        LaneCanvas(renderer: ruler, viewport: v)
                            .background(Color.black.opacity(0.25))
                            .gesture(scrubGesture)
                        Divider()
                        LaneCanvas(renderer: clips, viewport: v).laneBackground(0).gesture(laneTap(clips))
                        if !(info?.captions.isEmpty ?? true) {
                            LaneCanvas(renderer: captions, viewport: v).laneBackground(1).gesture(laneTap(captions))
                        }
                        ForEach(Array(score.enumerated()), id: \.element.title) { i, lane in
                            LaneCanvas(renderer: lane, viewport: v).laneBackground(i).gesture(laneTap(lane))
                        }
                        LaneCanvas(renderer: audio, viewport: v).laneBackground(0).gesture(laneTap(audio))
                        LaneCanvas(renderer: notes, viewport: v).laneBackground(1).gesture(laneTap(notes))
                        Color.clear.frame(maxHeight: .infinity).contentShape(Rectangle()).gesture(laneTap(nil))
                    }
                    PlayheadOverlay(model: model)
                    ScrollCatcher(
                        onPan: { dx in model.ui.viewport.pan(by: dx) },
                        onZoom: { f, x in model.ui.viewport.zoom(by: f, around: x) })
                }
                .onAppear { resize(geo.size.width) }
                .onChange(of: geo.size.width) { _, w in resize(w) }
            }
            .clipped()
        }
        .background(StudioStyle.laneBackground)
    }

    private func resize(_ w: CGFloat) {
        var nv = model.ui.viewport
        nv.resize(width: w)
        if nv != model.ui.viewport { model.ui.viewport = nv }
    }

    private func header(_ title: String, height: CGFloat, detail: String? = nil, warn: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(StudioStyle.laneLabel)
                .foregroundStyle(warn ? StudioStyle.warn.opacity(0.9) : .secondary)
            Spacer(minLength: 2)
            if let detail { Text(detail).font(.system(size: 9)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 10)
        .frame(height: height)
        .overlay(alignment: .bottom) { StudioStyle.hairline.frame(height: 1) }
    }

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                model.playback.pause()
                model.playback.seek(model.ui.viewport.t(g.location.x), precise: false)
            }
            .onEnded { g in model.playback.seek(model.ui.viewport.t(g.location.x), precise: true) }
    }

    /// Click: select what was hit (clip/comment) else seek. Double-click a clip: open its source.
    private func laneTap(_ lane: (any LaneRenderer)?) -> some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { e in
                guard let hit = lane?.hit(e.location, viewport: model.ui.viewport), hit.kind == .clip,
                      let src = model.info?.clips.first(where: { $0.id == hit.id })?.source else { return }
                SourceOpener.open(src)
            }
            .exclusively(before: SpatialTapGesture(count: 1).onEnded { e in
                let v = model.ui.viewport
                if let hit = lane?.hit(e.location, viewport: v) {
                    switch hit.kind {
                    case .clip: model.ui.selectedClipID = hit.id
                    case .comment:
                        model.review.selection = hit.id
                        model.ui.inspectorTab = .comments
                        model.playback.seek(hit.start, precise: true)
                        return
                    default: break
                    }
                }
                model.playback.seek(v.t(e.location.x), precise: true)
            })
    }
}

struct LaneCanvas<R: LaneRenderer>: View {
    var renderer: R
    var viewport: TimelineViewport

    var body: some View {
        Canvas { ctx, size in renderer.draw(in: &ctx, size: size, viewport: viewport) }
            .frame(height: renderer.height)
            .contentShape(Rectangle())
    }
}

private extension View {
    func laneBackground(_ i: Int) -> some View {
        background(i % 2 == 0 ? StudioStyle.laneBackground : StudioStyle.laneAltBackground)
            .overlay(alignment: .bottom) { StudioStyle.hairline.frame(height: 1) }
    }
}

struct TimelineZoomControls: View {
    @Bindable var model: ProjectModel
    var body: some View {
        HStack(spacing: 2) {
            Button { model.perform(.timelineZoomOut) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out (⌘−)")
            Button { model.perform(.timelineZoomIn) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in (⌘=)")
            Button { model.perform(.timelineZoomFit) } label: {
                Text("FIT").font(.system(size: 9, weight: .bold))
            }
            .help("Zoom to fit (⇧Z)")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
    }
}
