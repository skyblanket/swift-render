import SwiftUI
import SwiftRenderKit

// MARK: - Viewer
//
// HUD row (generation · timecode · frame — ms/frame · fps · drops), then the frame
// layer with guides, pins, region tool, compare and crash card layered over the same
// canvas rect.

struct ViewerView: View {
    @Bindable var model: ProjectModel

    var body: some View {
        VStack(spacing: 0) {
            ViewerHUDRow(model: model)
            if case .failed(let errors, _) = model.build.phase, !errors.isEmpty {
                BuildErrorBanner(model: model, errors: errors)
            }
            GeometryReader { geo in
                let zoom = model.ui.zoom
                let canvas = ViewerGeometry.canvasRect(container: geo.size, content: sceneSize, zoom: zoom,
                                                       inset: zoom == .fit ? 12 : 0)
                ZStack {
                    StudioStyle.viewerBackground
                    FrameLayerRepresentable(engine: model.playback, zoom: zoom, sceneSize: sceneSize)
                    if !model.playback.hasFrame { placeholder }
                    SafeAreaOverlay(mode: model.ui.guides, canvas: canvas)
                    PinsOverlay(model: model, canvas: canvas)
                    if model.ui.regionArmed { RegionTool(model: model, canvas: canvas) }
                    if let mode = model.ui.compare { CompareView(model: model, mode: mode, canvas: canvas) }
                    if let crash = model.host.crash {
                        CrashCard(model: model, crash: crash)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, 18)
                    }
                    if let toast = model.ui.toast { toastView(toast) }
                }
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.perform(.toggleZoomFit) }
            }
            .frame(minHeight: 220)
        }
    }

    private var sceneSize: CGSize {
        CGSize(width: model.info?.width ?? Int(model.aspect.size.width), height: model.info?.height ?? Int(model.aspect.size.height))
    }

    @ViewBuilder private var placeholder: some View {
        switch model.host.state {
        case .failed(let why):
            StudioEmptyState(title: "Render Host Unavailable", symbol: "bolt.horizontal.circle", message: why)
        case .ready where model.playback.poisoned.contains(frameIndex(model.playback.t, fps: model.playback.fps)):
            StudioEmptyState(title: "Frame Skipped", symbol: "exclamationmark.triangle",
                             message: "This frame crashed the host. It renders again after the next build.")
        default:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(placeholderText).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var placeholderText: String {
        if model.build.isBuilding { return "Building \(model.build.product)…" }
        if case .failed = model.build.phase, model.host.active == nil { return "Build failed — fix the errors above" }
        if case .ready = model.host.state { return model.selectedScene == nil ? "Choose a scene" : "Rendering…" }
        return "Starting render host…"
    }

    private func toastView(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 12)
            .task(id: text) {
                try? await Task.sleep(for: .seconds(3))
                if model.ui.toast == text { model.ui.toast = nil }
            }
    }
}

/// "● gen 42 · 00:12.40 · f744        9.8 ms/f · 30 fps · 0 drop"
struct ViewerHUDRow: View {
    @Bindable var model: ProjectModel

    var body: some View {
        let p = model.playback
        let s = p.stats
        HStack(spacing: 8) {
            Circle().fill(hostColor).frame(width: 7, height: 7)
            Text("gen \(model.host.generation)").foregroundStyle(.secondary)
            Text("·").foregroundStyle(.tertiary)
            PlayheadReadout(engine: p)
            if model.ui.regionArmed {
                StudioBadge(text: "REGION — drag on the frame · Esc", color: StudioStyle.accent)
            }
            Spacer()
            if let note = s.note { Text(note).foregroundStyle(StudioStyle.warn).lineLimit(1) }
            Text(String(format: "%.1f ms/f", s.msPerFrame))
            Text("·").foregroundStyle(.tertiary)
            Text(p.isPlaying ? String(format: "%.0f fps", s.shownFPS) : "\(s.targetFPS) fps")
            Text("·").foregroundStyle(.tertiary)
            Text("\(s.dropped) drop").foregroundStyle(s.dropped > 0 ? StudioStyle.warn : .secondary)
            if s.widthScale < 1 { StudioBadge(text: "\(Int(s.widthScale * 100))%", color: .secondary) }
        }
        .font(StudioStyle.monoSmall)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Color.black.opacity(0.35))
    }

    private var hostColor: Color {
        switch model.host.state {
        case .ready: return StudioStyle.ok
        case .starting, .swapping: return StudioStyle.warn
        case .crashed, .failed: return StudioStyle.bad
        case .idle: return .gray
        }
    }
}

/// The only HUD text that reads `t` (isolated so the rest of the row doesn't redraw at 60 Hz).
struct PlayheadReadout: View {
    var engine: PlaybackEngine
    var body: some View {
        HStack(spacing: 8) {
            Text(StudioStyle.timecode(engine.t)).foregroundStyle(.primary)
            Text("·").foregroundStyle(.tertiary)
            Text("f\(frameIndex(engine.t, fps: engine.fps))")
        }
    }
}
