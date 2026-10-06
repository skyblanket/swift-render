import AppKit
import SwiftUI
import SwiftRenderKit

// MARK: - Entry point
//
//   swift-render-studio [projectPath] [--scene X] [--at t] [--fake-host] [--snapshot out.png]
//
// `--snapshot` lays out a project window offscreen (no activation, no Dock icon),
// waits for the first frame, writes a PNG of the window and exits 0 — for agents and
// CI to look at the Studio UI itself.

@main
enum StudioMain {
    static func main() {
        let options = LaunchOptions.parse(Array(CommandLine.arguments.dropFirst()))
        MainActor.assumeIsolated {
            StudioLaunch.options = options
            if let out = options.snapshot {
                SnapshotRunner.run(options, out: out)
            } else {
                StudioApp.main()
            }
        }
    }
}

struct StudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Welcome to swift-render Studio", id: "welcome") {
            WelcomeView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        WindowGroup("Project", for: URL.self) { $root in
            if let root {
                ProjectWindow(root: root)
            }
        }
        .defaultSize(width: 1600, height: 1000)
        .commands { StudioCommands() }

        Settings { SettingsView() }
    }
}
