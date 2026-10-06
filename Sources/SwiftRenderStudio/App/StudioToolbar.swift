import SwiftUI
import SwiftRenderKit

// MARK: - Toolbar
//
// [scene ▾] │ 16:9 · 9:16 · 1:1 │ Fit ▾ │ Auto ▾ │ Guides │ A/B │ ● Built 1.3s │ Ask Claude │ Render │ [▤]

struct StudioToolbar: ToolbarContent {
    @Bindable var model: ProjectModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Menu {
                ForEach(model.scenes, id: \.name) { s in
                    Button { Task { await model.select(scene: s.name) } } label: {
                        Label(s.name, systemImage: StudioStyle.symbol(s.kind))
                    }
                }
            } label: {
                Label(model.selectedScene ?? "Scene", systemImage: StudioStyle.symbol(model.info?.kind ?? .render))
            }
            .help("Scene")
        }

        ToolbarItemGroup(placement: .principal) {
            Picker("Aspect", selection: Binding(get: { model.aspect }, set: { a in Task { await model.setAspect(a) } })) {
                ForEach(AspectChoice.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Canvas aspect")

            Menu {
                Picker("Zoom", selection: $model.ui.zoom) {
                    ForEach(ViewerZoom.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(model.ui.zoom.title, systemImage: "plus.magnifyingglass")
                    .labelStyle(.titleOnly)
            }
            .help("Viewer zoom (double-click the frame toggles Fit / 100%)")

            Menu {
                Picker("Quality", selection: Binding(get: { model.playback.quality }, set: { model.playback.quality = $0 })) {
                    ForEach(PlaybackQuality.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Text(model.playback.quality.title)
            }
            .help("Playback quality")

            Menu {
                Picker("Guides", selection: $model.ui.guides) {
                    ForEach(GuideMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: model.ui.guides == .off ? "squareshape.dashed.squareshape" : "squareshape.split.3x3")
            } primaryAction: {
                model.perform(.cycleGuides)
            }
            .help("Guides (G cycles)")

            Button { model.perform(.newComment) } label: {
                Label("Comment", systemImage: "plus.bubble")
            }
            .help("New comment at the playhead (C) · R or ⌥-drag marks a region")

            Toggle(isOn: Binding(get: { model.ui.compare != nil }, set: { _ in model.perform(.toggleCompare) })) {
                Label("A/B", systemImage: "rectangle.split.2x1")
            }
            .help("A/B compare (\\)")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            BuildPill(model: model)

            Button { model.perform(.askAgent) } label: {
                Label("Ask Claude", systemImage: "sparkles")
            }
            .help("Ask Claude about open comments (⌘⇧A)")

            Button { model.perform(.renderSheet) } label: {
                Label("Render", systemImage: "film.stack")
            }
            .help("Render… (⌘⇧R)")

            RenderActivityButton(model: model)

            Button { model.perform(.toggleInspector) } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Toggle inspector (⌘⌥I)")
        }
    }
}
