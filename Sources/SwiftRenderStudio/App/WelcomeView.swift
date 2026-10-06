import AppKit
import SwiftUI
import SwiftRenderKit

// MARK: - Welcome

struct WelcomeView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var recents = Recents.all

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "film.stack.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(StudioStyle.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("swift-render Studio").font(.system(size: 26, weight: .bold))
                    Text("Launch films for Swift codebases").foregroundStyle(.secondary)
                }
                Spacer().frame(height: 6)
                action("Open Project…", "folder", "⌘O") { if let url = Self.chooseProject() { open(url) } }
                action("New Launch Film from Codebase…", "sparkles.tv", nil) {
                    if let url = Self.chooseProject() { open(url) }
                }
                Spacer()
            }
            .padding(32)
            .frame(width: 330, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                Text("Recent").font(.headline).padding(16)
                if recents.isEmpty {
                    ContentUnavailableView("No recent projects", systemImage: "clock",
                                           description: Text("Open a package whose executable links SwiftRenderTool."))
                } else {
                    List(recents, id: \.self) { url in
                        Button { open(url) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.lastPathComponent).font(.body.weight(.medium))
                                Text(url.path(percentEncoded: false)).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.head)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(width: 360)
        }
        .frame(height: 380)
        .preferredColorScheme(.dark)
        .onAppear {
            if let p = StudioLaunch.options.projectPath {
                StudioLaunch.options.projectPath = nil      // only the first time
                open(p)
            }
        }
    }

    private func action(_ title: String, _ symbol: String, _ shortcut: String?, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack {
                Image(systemName: symbol).frame(width: 20)
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(.tertiary) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(size: 13, weight: .medium))
    }

    private func open(_ url: URL) {
        let root = Project.discover(from: url)?.root ?? url
        Recents.add(root)
        openWindow(value: root)
        dismissWindow(id: "welcome")
    }

    @MainActor
    static func chooseProject() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Swift package that uses swift-render"
        panel.prompt = "Open"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
