import AppKit
import SwiftUI

// MARK: - Menus
//
// Modified shortcuts are real key equivalents here. Unmodified keys (Space, J/K/L, I/O,
// C, R, G…) are NOT menu key equivalents: AppKit matches those before a text field sees
// keyDown, so typing "j" in the composer would shuttle playback. KeyRouter handles them,
// and Help › Keyboard Shortcuts lists them.

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
    @AppStorage(StudioAppearance.key) private var appearance = StudioAppearance.fallback.rawValue

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
            Button("Play or Pause") { run(.playPause) }
            Button("Play Forward") { run(.shuttle(.l)) }
            Button("Play Backward") { run(.shuttle(.j)) }
            Divider()
            Button("Next Frame") { run(.stepFrames(1)) }
            Button("Previous Frame") { run(.stepFrames(-1)) }
            Button("Next Edit") { run(.jumpEdit(next: true)) }
            Button("Previous Edit") { run(.jumpEdit(next: false)) }
            Divider()
            Button("Set In") { run(.setIn) }
            Button("Set Out") { run(.setOut) }
            Button("Clear Range") { run(.clearInOut) }
            Button("Loop Range") { run(.loopInOut) }
        }

        CommandMenu("Comments") {
            Button("New Comment at Playhead") { run(.newComment) }
            Button("Mark a Spot on the Frame") { run(.armRegion) }
            Divider()
            Button("Next Comment") { run(.selectComment(next: true)) }
            Button("Previous Comment") { run(.selectComment(next: false)) }
            Divider()
            Button("Compare Before and After") { run(.toggleCompare) }
        }

        CommandMenu("Build") {
            Button("Rebuild Now") { run(.build) }
                .keyboardShortcut("b")
            Button("Stop") { run(.stop) }
                .keyboardShortcut(".")
            Divider()
            Button("Open Scene Source") { run(.openSource) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }

        CommandMenu("Claude") {
            Button("Ask Claude…") { run(.askAgent) }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button(model?.ui.showAgentPanel == true ? "Hide Claude Panel" : "Show Claude Panel") { run(.toggleAgentPanel) }
                .keyboardShortcut("j", modifiers: [.command, .option])
        }

        CommandMenu("Export") {
            Button("Export Again") { run(.render) }
                .keyboardShortcut("r")
            Button("Export…") { run(.renderSheet) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }

        CommandGroup(after: .sidebar) {
            Button("Show or Hide Scenes") { run(.toggleSidebar) }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Show or Hide Inspector") { run(.toggleInspector) }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            Button("Comments") { run(.inspectorTab(.comments)) }.keyboardShortcut("1")
            Button("Knobs") { run(.inspectorTab(.knobs)) }.keyboardShortcut("2")
            Button("Content") { run(.inspectorTab(.props)) }.keyboardShortcut("3")
            Button("Info") { run(.inspectorTab(.info)) }.keyboardShortcut("4")
            Divider()
            Button("Zoom Timeline In") { run(.timelineZoomIn) }.keyboardShortcut("=")
            Button("Zoom Timeline Out") { run(.timelineZoomOut) }.keyboardShortcut("-")
            Button("Zoom Timeline to Fit") { run(.timelineZoomFit) }
            Divider()
            Button("Next Guide") { run(.cycleGuides) }
            if PlaybackStats.debugOverlayEnabled {
                Toggle("Show Playback Statistics", isOn: Binding(get: { model?.ui.showStats ?? false },
                                                                 set: { _ in run(.toggleStats) }))
            }
            Picker("Appearance", selection: Binding(get: { appearance }, set: { raw in
                appearance = raw
                NSApp.appearance = (StudioAppearance(rawValue: raw) ?? StudioAppearance.fallback).nsAppearance
            })) {
                ForEach(StudioAppearance.allCases) { Text($0.title).tag($0.rawValue) }
            }
        }

        CommandGroup(after: .help) {
            Button("Keyboard Shortcuts") { openWindow(id: "shortcuts") }
                .keyboardShortcut("/", modifiers: [.command, .shift])
        }
    }
}

/// Help › Keyboard Shortcuts: the single keys KeyRouter handles, and the ⌘ ones.
struct ShortcutsView: View {
    private static let groups: [(String, [(String, String)])] = [
        ("Playback", [("Space", "Play or pause"), ("J  K  L", "Play backward, stop, play forward (hold K and tap J or L to step)"),
                      ("←  →", "Previous or next frame"), ("⇧←  ⇧→", "Back or ahead one second"),
                      ("↑  ↓", "Previous or next edit"), ("Home  End", "Start or end")]),
        ("Range", [("I  O", "Set In or Out"), ("⇧I  ⇧O", "Go to In or Out"), ("⌥X", "Clear the range"), ("/", "Loop the range")]),
        ("Comments", [("C", "Comment at the playhead"), ("R", "Mark a spot on the frame (or hold ⌥ and drag)"),
                      ("[  ]", "Previous or next comment"), ("\\", "Compare before and after"), ("|", "Next compare mode"),
                      ("⌘↩", "Post"), ("⌘⇧↩", "Post and ask Claude")]),
        ("View", [("G", "Next guide"), ("⇧Z", "Zoom the timeline to fit"), ("⌘=  ⌘−", "Zoom the timeline in or out"),
                  ("⌘1 … ⌘4", "Comments, Knobs, Content, Info")]),
        ("Actions", [("⌘⇧A", "Ask Claude"), ("⌘R", "Export again"), ("⌘⇧R", "Export…"), ("⌘B", "Rebuild now"), ("⌘.", "Stop")]),
    ]

    var body: some View {
        Form {
            ForEach(Self.groups, id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1, id: \.0) { key, what in
                        LabeledContent(what) {
                            Text(key).font(StudioStyle.Fonts.body.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 560)
    }
}
