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

    var body: some View {
        TabView {
            Form {
                Picker("Open sources in", selection: $editor) {
                    ForEach(EditorChoice.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Section("Tool paths (empty = login shell PATH)") {
                    TextField("swift", text: $swiftPath, prompt: Text("/usr/bin/swift"))
                    TextField("claude", text: $claudePath, prompt: Text("~/.local/bin/claude"))
                    TextField("git", text: $gitPath, prompt: Text("/usr/bin/git"))
                    TextField("ffmpeg", text: $ffmpegPath, prompt: Text("/opt/homebrew/bin/ffmpeg"))
                }
            }
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Picker("Default quality", selection: $quality) {
                    ForEach(PlaybackQuality.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Stepper("Frame cache: \(cacheBudgetMB) MB", value: $cacheBudgetMB, in: 256...8192, step: 256)
            }
            .tabItem { Label("Playback", systemImage: "play.rectangle") }

            Form {
                TextField("Model", text: $agentModel, prompt: Text("default"))
                TextField("Budget per run (USD)", value: $agentBudget, format: .number)
            }
            .tabItem { Label("Agent", systemImage: "sparkles") }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 300)
    }
}
