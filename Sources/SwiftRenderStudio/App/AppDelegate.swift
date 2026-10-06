import AppKit

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
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
