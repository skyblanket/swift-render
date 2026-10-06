import SwiftUI

// MARK: - Inspector
//
// Comments · Knobs · Content · Info (⌘1–⌘4). Trailing `.inspector` column: native,
// full height, resizable, toggled from the toolbar (⌘⌥I).

struct InspectorView: View {
    @Bindable var model: ProjectModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $model.ui.inspectorTab) {
                ForEach(InspectorTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
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
        }
        .task(id: model.info?.name) { await model.inspector.sceneOpened() }
    }
}
