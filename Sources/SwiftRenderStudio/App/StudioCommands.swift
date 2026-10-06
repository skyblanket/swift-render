import AppKit
import SwiftUI

// MARK: - Menus
//
// Modified shortcuts live here. Unmodified keys (Space, J/K/L, I/O, C, R, G…) are NOT
// menu key equivalents — AppKit matches those before a text field sees keyDown, so
// typing "j" in the composer would shuttle playback. KeyRouter handles them; the
// menus show them as hints only.

struct ProjectFocusKey: FocusedValueKey {
    typealias Value = ProjectModel
}

extension FocusedValues {
    var project: ProjectModel? {
        get { self[ProjectFocusKey.self] }
        set { self[ProjectFocusKey.self] = newValue }
    }
}

struct StudioCommands: Commands {
    @FocusedValue(\.project) private var model: ProjectModel?
    @Environment(\.openWindow) private var openWindow

    private func run(_ a: StudioAction) { model?.perform(a) }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Project…") {
                if let url = WelcomeView.chooseProject() { openWindow(value: url) }
            }
            .keyboardShortcut("o")
            Button("Welcome Window") { openWindow(id: "welcome") }
                .keyboardShortcut("0", modifiers: [.command, .shift])
        }

        CommandMenu("Playback") {
            Button("Play / Pause  (Space)") { run(.playPause) }
            Button("Shuttle  (J · K · L)") { run(.shuttle(.l)) }
            Button("Previous / Next Frame  (← →)") { run(.stepFrames(1)) }
            Button("Previous / Next Edit  (↑ ↓)") { run(.jumpEdit(next: true)) }
            Divider()
            Button("Set In  (I)") { run(.setIn) }
            Button("Set Out  (O)") { run(.setOut) }
            Button("Clear In/Out  (⌥X)") { run(.clearInOut) }
            Button("Loop In→Out  (/)") { run(.loopInOut) }
        }

        CommandMenu("Review") {
            Button("New Comment at Playhead  (C)") { run(.newComment) }
            Button("Mark Region  (R)") { run(.armRegion) }
            Button("Previous / Next Comment  ([ ])") { run(.selectComment(next: true)) }
            Divider()
            Button("Toggle A/B Compare  (\\)") { run(.toggleCompare) }
            Button("Cycle Guides  (G)") { run(.cycleGuides) }
        }

        CommandMenu("Build") {
            Button("Build Now") { run(.build) }
                .keyboardShortcut("b")
            Button("Stop") { run(.stop) }
                .keyboardShortcut(".")
            Divider()
            Button("Open Scene Source") { run(.openSource) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }

        CommandMenu("Agent") {
            Button("Ask Claude…") { run(.askAgent) }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Show Agent Panel") { run(.toggleAgentPanel) }
                .keyboardShortcut("j", modifiers: [.command, .option])
        }

        CommandMenu("Render") {
            Button("Render with Last Preset") { run(.render) }
                .keyboardShortcut("r")
            Button("Render…") { run(.renderSheet) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }

        CommandGroup(after: .sidebar) {
            Button("Toggle Scenes Sidebar") { run(.toggleSidebar) }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Toggle Inspector") { run(.toggleInspector) }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            Button("Comments") { run(.inspectorTab(.comments)) }.keyboardShortcut("1")
            Button("Knobs") { run(.inspectorTab(.knobs)) }.keyboardShortcut("2")
            Button("Props") { run(.inspectorTab(.props)) }.keyboardShortcut("3")
            Button("Info") { run(.inspectorTab(.info)) }.keyboardShortcut("4")
            Divider()
            Button("Zoom Timeline In") { run(.timelineZoomIn) }.keyboardShortcut("=")
            Button("Zoom Timeline Out") { run(.timelineZoomOut) }.keyboardShortcut("-")
            Button("Zoom Timeline to Fit  (⇧Z)") { run(.timelineZoomFit) }
        }
    }
}
