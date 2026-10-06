import AppKit
import SwiftUI

// MARK: - Settings

struct SettingsView: View {
    @AppStorage(SourceOpener.defaultsKey) private var editor = EditorChoice.xcode.rawValue
    @AppStorage(ToolPaths.overrideKey("swift")) private var swiftPath = ""
    @AppStorage(ToolPaths.overrideKey("claude")) private var claudePath = ""
    @AppStorage(ToolPaths.overrideKey("git")) private var gitPath = ""
    @AppStorage(ToolPaths.overrideKey("ffmpeg")) private var ffmpegPath = ""
    @AppStorage("cacheBudgetMB") private var cacheBudgetMB = 1024
    @AppStorage("playbackQuality") private var quality = PlaybackQuality.auto.rawValue
    @AppStorage("agentModel") private var agentModel = ""
    @AppStorage("agentBudgetUSD") private var agentBudget = 2.0
    @AppStorage(StudioAppearance.key) private var appearance = StudioAppearance.fallback.rawValue

    var body: some View {
        TabView {
            Form {
                Picker("Appearance", selection: $appearance) {
                    ForEach(StudioAppearance.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .onChange(of: appearance) { _, raw in
                    NSApp.appearance = (StudioAppearance(rawValue: raw) ?? StudioAppearance.fallback).nsAppearance
                }
                Picker("Open Code In", selection: $editor) {
                    ForEach(EditorChoice.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Section {
                    TextField("Swift", text: $swiftPath, prompt: Text("/usr/bin/swift"))
                    TextField("Claude Code", text: $claudePath, prompt: Text("~/.local/bin/claude"))
                    TextField("Git", text: $gitPath, prompt: Text("/usr/bin/git"))
                    TextField("ffmpeg", text: $ffmpegPath, prompt: Text("/opt/homebrew/bin/ffmpeg"))
                } header: {
                    Text("Tool Locations")
                } footer: {
                    Text("Leave these empty and Studio finds them the way your Terminal does.")
                        .font(StudioStyle.Fonts.subheadline).foregroundStyle(.secondary)
                }
            }
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Picker("Quality", selection: $quality) {
                    ForEach(PlaybackQuality.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Stepper("Frame Memory: \(cacheBudgetMB) MB", value: $cacheBudgetMB, in: 256...8192, step: 256)
            }
            .tabItem { Label("Playback", systemImage: "play.rectangle") }

            Form {
                TextField("Model", text: $agentModel, prompt: Text("Default"))
                TextField("Spend Up To (USD)", value: $agentBudget, format: .number)
            }
            .tabItem { Label("Claude", systemImage: "text.bubble") }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 340)
    }
}
