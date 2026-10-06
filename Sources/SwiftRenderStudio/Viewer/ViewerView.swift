import SwiftUI
import SwiftRenderKit

// MARK: - Viewer
//
// A header with the viewer's own controls (Aspect · Zoom · View), the build banner when
// the build failed, then the picture with its keyline, guides, pins, region tool,
// compare and crash card layered over the same canvas rect.

struct ViewerView: View {
    @Bindable var model: ProjectModel

    var body: some View {
        VStack(spacing: 0) {
            ViewerHeader(model: model)
            if case .failed(let errors, _) = model.build.phase, !errors.filter({ $0.severity == .error }).isEmpty {
                BuildErrorBanner(model: model, errors: errors.filter { $0.severity == .error })
            }
            GeometryReader { geo in
                let zoom = model.ui.zoom
                let canvas = ViewerGeometry.canvasRect(container: geo.size, content: sceneSize, zoom: zoom,
                                                       inset: zoom == .fit ? ViewerGeometry.fitInset : 0)
                ZStack {
                    surround
                    FrameLayerRepresentable(engine: model.playback, zoom: zoom, sceneSize: sceneSize)
                    // A 1 px keyline so a black frame still has an edge.
                    Rectangle()
                        .strokeBorder(StudioStyle.keyline, lineWidth: 1)
                        .frame(width: canvas.width + 2, height: canvas.height + 2)
                        .position(x: canvas.midX, y: canvas.midY)
                        .allowsHitTesting(false)
                    if !model.playback.hasFrame { placeholder }
                    SafeAreaOverlay(mode: model.ui.guides, canvas: canvas)
                    PinsOverlay(model: model, canvas: canvas)
                    if let mode = model.ui.compare { CompareView(model: model, mode: mode, canvas: canvas) }
                    // Always present: R arms it, ⌥ activates it, and it hosts the region composer.
                    RegionTool(model: model, canvas: canvas)
                    if model.ui.regionArmed { hint("Drag a box around the spot · Esc to cancel") }
                    if model.ui.showStats { PlaybackStatsOverlay(engine: model.playback) }
                    if let crash = model.host.crash {
                        CrashCard(model: model, crash: crash)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, StudioStyle.Space.l)
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

    @ViewBuilder private var surround: some View {
        switch model.ui.viewerBackground {
        case .automatic: StudioStyle.canvas
        case .black: Color.black
        case .gray: Color(nsColor: .systemGray)
        case .white: Color.white
        }
    }

    @ViewBuilder private var placeholder: some View {
        let scene = model.selectedScene ?? "This scene"
        let buildErrors = model.build.errors.count
        if case .failed = model.build.phase, buildErrors > 0, model.host.active == nil {
            StudioEmptyState(title: "\(scene) didn't build", symbol: StudioStyle.Symbol.build,
                             message: "Fix the \(buildErrors == 1 ? "error" : "\(buildErrors) errors") above and it'll play again.",
                             actionTitle: "Ask Claude to Fix") { model.perform(.askAgent) }
        } else {
            switch model.host.state {
            case .failed(let why):
                StudioEmptyState(title: "The preview stopped", symbol: StudioStyle.Symbol.build,
                                 message: "Studio couldn't open \(scene). Save a change to try again.")
                    .help(why)
            case .ready where model.playback.poisoned.contains(frameIndex(model.playback.t, fps: model.playback.fps)):
                StudioEmptyState(title: "This frame crashed", symbol: "exclamationmark.triangle",
                                 message: "Studio skipped it. It'll try again after your next save.")
            default:
                VStack(spacing: StudioStyle.Space.s) {
                    ProgressView().controlSize(.small)
                    Text(placeholderText).font(StudioStyle.Fonts.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var placeholderText: String {
        if model.build.isBuilding && model.host.active == nil { return "Building…" }
        if case .ready = model.host.state { return model.selectedScene == nil ? "Pick a scene on the left" : "Loading…" }
        return "Warming up…"
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(StudioStyle.Fonts.callout)
            .padding(.horizontal, StudioStyle.Space.m).padding(.vertical, 6)
            .studioGlass(cornerRadius: 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, StudioStyle.Space.m)
            .allowsHitTesting(false)
    }

    private func toastView(_ text: String) -> some View {
        Text(text)
            .font(StudioStyle.Fonts.callout)
            .padding(.horizontal, StudioStyle.Space.m).padding(.vertical, 7)
            .studioGlass(cornerRadius: 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, StudioStyle.Space.m)
            .task(id: text) {
                try? await Task.sleep(for: .seconds(3))
                if model.ui.toast == text { model.ui.toast = nil }
            }
    }
}

/// Aspect on the leading edge; Zoom and View on the trailing edge.
struct ViewerHeader: View {
    @Bindable var model: ProjectModel

    var body: some View {
        HStack(spacing: StudioStyle.Space.m) {
            Menu {
                Picker("Aspect", selection: Binding(get: { model.aspect }, set: { a in Task { await model.setAspect(a) } })) {
                    ForEach(AspectChoice.allCases) { Text(Self.aspectTitle($0)).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Text(model.aspect.rawValue)
            }
            .help("Canvas shape")
            Spacer(minLength: StudioStyle.Space.s)
            Menu {
                Picker("Zoom", selection: $model.ui.zoom) {
                    ForEach(ViewerZoom.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Text(model.ui.zoom.title)
            }
            .help("Zoom (double-click the picture to switch between Fit and 100%)")
            ViewMenu(model: model)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .font(StudioStyle.Fonts.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, StudioStyle.Space.m)
        .frame(height: 30)
        .background(StudioStyle.chrome)
        .overlay(alignment: .bottom) { StudioStyle.hairline.frame(height: 1) }
    }

    static func aspectTitle(_ a: AspectChoice) -> String {
        switch a {
        case .landscape: return "16:9  Widescreen"
        case .vertical: return "9:16  Portrait"
        case .square: return "1:1  Square"
        }
    }
}

/// Quality, Guides, Background and Playback Statistics.
struct ViewMenu: View {
    @Bindable var model: ProjectModel

    var body: some View {
        Menu {
            Picker("Quality", selection: Binding(get: { model.playback.quality }, set: { model.playback.quality = $0 })) {
                ForEach(PlaybackQuality.allCases) { Text($0.title).tag($0) }
            }
            Picker("Guides", selection: $model.ui.guides) {
                ForEach(GuideMode.allCases) { Text($0.title).tag($0) }
            }
            Picker("Background", selection: Binding(get: { model.ui.viewerBackground }, set: {
                model.ui.viewerBackground = $0
                UserDefaults.standard.set($0.rawValue, forKey: "viewer.background")
            })) {
                ForEach(ViewerBackground.allCases) { Text($0.title).tag($0) }
            }
            Divider()
            Toggle("Show Playback Statistics", isOn: Binding(get: { model.ui.showStats }, set: { _ in model.perform(.toggleStats) }))
        } label: {
            Text("View")
        }
        .fixedSize()
        .help("Quality, guides (G) and background")
    }
}

/// View › Show Playback Statistics: a small material label in the viewer's corner.
struct PlaybackStatsOverlay: View {
    var engine: PlaybackEngine

    var body: some View {
        let s = engine.stats
        VStack(alignment: .trailing, spacing: 2) {
            Text(engine.isPlaying ? String(format: "Playing %.0f of %d fps · %d dropped", s.shownFPS, s.targetFPS, s.dropped)
                                  : "Paused · \(s.targetFPS) fps")
            Text(String(format: "%.1f ms per frame", s.msPerFrame) + (s.widthScale < 1 ? " · \(Int(s.widthScale * 100))% size" : ""))
                .foregroundStyle(.secondary)
            if let note = s.note { Text(note).foregroundStyle(.secondary) }
        }
        .font(StudioStyle.Fonts.subheadline)
        .monospacedDigit()
        .padding(.horizontal, 10).padding(.vertical, 6)
        .studioGlass(cornerRadius: StudioStyle.Radius.medium)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(StudioStyle.Space.m)
        .allowsHitTesting(false)
    }
}
