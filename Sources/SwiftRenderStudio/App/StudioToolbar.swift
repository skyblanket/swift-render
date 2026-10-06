import SwiftUI
import SwiftRenderKit

// MARK: - Toolbar
//
//   [Scene title ▾]        [ Up to date ]        Comment · Compare · Ask Claude · Export · [▤]
//
// The window title is the scene switcher (`.toolbarTitleMenu`). The principal slot holds an
// Xcode-style activity view that opens the diagnostics popover. Viewer controls (aspect,
// zoom, quality, guides) live in the viewer's own header, next to the picture.

struct StudioToolbar: ToolbarContent {
    @Bindable var model: ProjectModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            ActivityView(model: model)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.perform(.newComment) } label: {
                Label("Comment", systemImage: StudioStyle.Symbol.comment)
            }
            .help("Comment at the playhead (C). Press R, or hold ⌥ and drag, to mark a spot on the frame.")

            Toggle(isOn: Binding(get: { model.ui.compare != nil }, set: { _ in model.perform(.toggleCompare) })) {
                Label("Compare", systemImage: StudioStyle.Symbol.compare)
            }
            .help("Compare before and after (\\)")

            Button { model.perform(.askAgent) } label: {
                Text("Ask Claude")
            }
            .help("Ask Claude to work on your comments (⌘⇧A)")

            ExportToolbarButton(model: model)
        }

        ToolbarItem(placement: .primaryAction) {
            Button { model.perform(.toggleInspector) } label: {
                Label("Inspector", systemImage: StudioStyle.Symbol.inspector)
            }
            .help("Show or hide the inspector (⌘⌥I)")
        }
    }
}
