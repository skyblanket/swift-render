import Foundation

// MARK: - Actions
//
// Every keyboard shortcut, menu command and toolbar button funnels into one
// `ProjectModel.perform(_:)`, so KeyRouter, StudioCommands and the toolbar never
// disagree, and work packages extend behavior in one switch instead of three places.

enum InspectorTab: String, CaseIterable, Identifiable, Sendable {
    case comments, knobs, props, info
    var id: String { rawValue }
    var title: String {
        switch self {
        case .comments: return "Comments"
        case .knobs: return "Knobs"
        case .props: return "Content"
        case .info: return "Info"
        }
    }
    var symbol: String {
        switch self {
        case .comments: return "text.bubble"
        case .knobs: return "slider.horizontal.3"
        case .props: return "doc.richtext"
        case .info: return "info.circle"
        }
    }
}

enum StudioAction: Equatable, Sendable {
    // Transport
    case playPause
    case shuttle(ShuttleKey)
    case stepFrames(Int)
    case stepSeconds(Double)
    case jumpEdit(next: Bool)
    case home, end
    case setIn, setOut, goIn, goOut, clearInOut, loopInOut
    // Review
    case newComment
    case armRegion
    case selectComment(next: Bool)
    // Viewer
    case toggleCompare, cycleCompare, cycleGuides
    case toggleZoomFit
    // Timeline
    case timelineZoomIn, timelineZoomOut, timelineZoomFit
    // Build / agent / render
    case build
    case render, renderSheet
    case askAgent
    case stop
    case openSource
    /// ⌫ / Edit › Delete: the selected comment, after a confirmation.
    case deleteSelection
    // Layout
    case inspectorTab(InspectorTab)
    case toggleInspector, toggleSidebar, toggleAgentPanel, toggleStats
    /// Esc: cancel tool, close popover, exit compare.
    case cancel
}
