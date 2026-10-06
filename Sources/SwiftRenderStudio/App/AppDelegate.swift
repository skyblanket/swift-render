import AppKit

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let seconds = ProcessInfo.processInfo.environment["SR_STUDIO_SELFTEST"].flatMap(Double.init) {
            SelfTest.run(after: seconds)
            return
        }
        // A bare `swift run` binary isn't a bundle: without this it can launch behind
        // other apps and never become key.
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)      // a pro video app: always dark
        if Bundle.main.bundleIdentifier == nil, let icon = NSImage(systemSymbolName: "film.stack.fill", accessibilityDescription: nil) {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate()
        // Children (swift build, hosts, claude) need the login shell's PATH.
        Task.detached(priority: .userInitiated) { ToolPaths.installLoginPATH() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await ProjectStore.shared.shutdownAll()     // hosts get `shutdown`, builds SIGINT
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// `SR_STUDIO_SELFTEST=<seconds>`: launches the real app (Welcome → project window via
/// `openWindow`, KeyRouter, model start) without activating it, keeps its windows off
/// screen, then prints what it ended up with and quits through the normal terminate
/// path. Exit 0 when a project window shows a frame.
@MainActor
enum SelfTest {
    static func run(after seconds: Double) {
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let started = Date()
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            MainActor.assumeIsolated {
                for w in NSApp.windows where w.frame.minX > -20_000 && w.isVisible {
                    w.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))     // never on the user's screen
                }
                guard Date().timeIntervalSince(started) > seconds else { return }
                timer.invalidate()
                report()
            }
        }
    }

    private static func report() {
        let titles = NSApp.windows.map { "\"\($0.title)\"\($0.isVisible ? "" : " (hidden)")" }
        let models = ProjectStore.shared.allModels
        print("[studio selftest] windows: \(titles.joined(separator: ", "))")
        for m in models {
            print("[studio selftest] project \(m.project.root.lastPathComponent): scene \(m.selectedScene ?? "-"), "
                  + "host \(m.host.state), build \(m.build.phase), frame \(m.playback.hasFrame)")
        }
        let ok = models.contains { $0.playback.hasFrame }
        Task {
            await ProjectStore.shared.shutdownAll()
            exit(ok ? 0 : 1)
        }
    }
}
