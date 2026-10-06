import SwiftUI

// MARK: - Inspector
//
// Comments · Knobs · Props · Info (⌘1–⌘4). Trailing `.inspector` column: native,
// full height, resizable, toggled from the toolbar (⌘⌥I).

struct InspectorView: View {
    @Bindable var model: ProjectModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $model.ui.inspectorTab) {
                ForEach(InspectorTab.allCases) { tab in
                    Text(label(tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
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
    }

    private func label(_ tab: InspectorTab) -> String {
        switch tab {
        case .comments:
            let n = model.review.openCount + model.review.inProgressCount
            return n > 0 ? "Comments \(n)" : "Comments"
        case .knobs:
            let n = model.info?.knobs.count ?? 0
            return n > 0 ? "Knobs \(n)" : "Knobs"
        default: return tab.title
        }
    }
}
