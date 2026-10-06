import SwiftUI

// MARK: - Inspector
//
// Comments · Knobs · Content · Info (⌘1–⌘4). Trailing `.inspector` column: native,
// full height, resizable, toggled from the toolbar (⌘⌥I).

struct InspectorView: View {
    @Bindable var model: ProjectModel

    var body: some View {
        VStack(spacing: 0) {
            StudioSegmented(options: InspectorTab.allCases, selection: $model.ui.inspectorTab) { $0.title }
            .padding(.horizontal, StudioStyle.Space.m)
            .padding(.vertical, StudioStyle.Space.s)
            Divider()
            Group {
                switch model.ui.inspectorTab {
                case .comments: CommentsTab(model: model)
                case .knobs: KnobsTab(model: model)
                case .props: PropsTab(model: model)
                case .info: InfoTab(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Another scene's knobs/props/info are never shown under this scene's name.
            .opacity(model.ui.inspectorTab != .comments && model.sceneDataIsStale ? 0 : 1)
            // Knobs, props and info come with the scene being opened; comments are already its own.
            .overlay {
                if model.ui.inspectorTab != .comments {
                    LoadingVeil(active: model.isSceneLoading, rows: 4, stale: model.sceneDataIsStale,
                                message: model.openFailure.map { "Nothing to show until \($0.scene) opens." })
                }
            }
        }
        .task(id: model.info?.name) { await model.inspector.sceneOpened() }
    }
}
