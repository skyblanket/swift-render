import AppKit
import SwiftUI
import SwiftRenderKit

// MARK: - Welcome
//
// Open a project (or start a launch film), see how the loop works in three steps, and
// pick up a recent project on the right.

struct WelcomeView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var recents = Recents.all
    @AppStorage(StudioAppearance.key) private var appearance = StudioAppearance.fallback.rawValue

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: StudioStyle.Space.l) {
                Image(systemName: StudioStyle.Symbol.film)
                    .font(StudioStyle.Fonts.emptyGlyph)
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(StudioStyle.accent, in: StudioStyle.rounded(StudioStyle.Radius.large))
                VStack(alignment: .leading, spacing: StudioStyle.Space.xs) {
                    Text("swift-render Studio").font(.largeTitle.weight(.semibold))
                    Text("Make films with SwiftUI, then polish them with Claude.")
                        .font(StudioStyle.Fonts.body).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: StudioStyle.Space.s) {
                    step(1, "Open a Swift package that uses swift-render.")
                    step(2, "Watch your film. Press C to leave a comment on any moment.")
                    step(3, "Ask Claude to fix it. Changes play the moment they build.")
                }
                .padding(.vertical, StudioStyle.Space.xs)
                Spacer(minLength: 0)
                HStack(spacing: StudioStyle.Space.s) {
                    Button("Open Project…") { if let url = Self.chooseProject() { open(url) } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("o")
                    Button("New Launch Film…") { if let url = Self.chooseProject() { open(url) } }
                        .help("Pick an app's folder and Studio drafts a launch film from it")
                }
                .controlSize(.large)
            }
            .padding(StudioStyle.Space.xl + StudioStyle.Space.s)
            .frame(width: 400, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                Text("Recent").font(StudioStyle.Fonts.headline)
                    .padding(.horizontal, StudioStyle.Space.l).padding(.top, StudioStyle.Space.l).padding(.bottom, StudioStyle.Space.s)
                if recents.isEmpty {
                    StudioEmptyState(title: "No recent projects", symbol: "clock",
                                     message: "Projects you open show up here.")
                } else {
                    List(recents, id: \.self) { url in
                        Button { open(url) } label: {
                            HStack(spacing: StudioStyle.Space.s) {
                                Image(systemName: "folder").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(url.lastPathComponent).font(StudioStyle.Fonts.bodyEmphasis)
                                    Text(url.path(percentEncoded: false)).font(StudioStyle.Fonts.subheadline).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.head)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 2)
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(width: 340)
            .background(StudioStyle.chromeAlt)
        }
        .frame(height: 420)
        .preferredColorScheme(scheme)
        .onAppear {
            if let p = StudioLaunch.options.projectPath {
                StudioLaunch.options.projectPath = nil      // only the first time
                open(p)
            }
        }
    }

    private var scheme: ColorScheme? {
        if let a = StudioLaunch.options.appearance { return a.colorScheme }
        return (StudioAppearance(rawValue: appearance) ?? StudioAppearance.fallback).colorScheme
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: StudioStyle.Space.s) {
            Text("\(n)")
                .font(StudioStyle.Fonts.rounded(11, weight: .bold))
                .foregroundStyle(StudioStyle.discInk)
                .frame(width: 20, height: 20)
                .background(StudioStyle.discFill, in: Circle())
            Text(text).font(StudioStyle.Fonts.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
