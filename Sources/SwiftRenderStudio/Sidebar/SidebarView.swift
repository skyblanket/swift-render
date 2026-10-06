import SwiftUI
import SwiftRenderKit

// MARK: - Sidebar
//
// Scenes (kind icon, open-comment badge) · Comments (Open, Ready for Review: each opens
// that segment) · Exports (recent files) · a + menu to add a scene or a launch film.

struct SidebarView: View {
    @Bindable var model: ProjectModel

    var body: some View {
        // The footer sits below the list (not in a safe-area inset) so rows never scroll under it.
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                list
                    .onChange(of: model.selectedScene) { _, name in
                        // A pick from the title menu: bring the row into view (no centering).
                        if let name { withAnimation { proxy.scrollTo(name) } }
                    }
            }
            footer
        }
    }

    private var list: some View {
        List(selection: Binding(get: { model.selectedScene }, set: { name in
            if let name { Task { await model.select(scene: name) } }
        })) {
            Section("Scenes") {
                if model.scenes.isEmpty {
                    if case .failed = model.build.phase {
                        Text("Scenes appear after a good build.")
                            .font(StudioStyle.Fonts.subheadline).foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: StudioStyle.Space.s) {
                            ProgressView().controlSize(.small)
                            Text("Getting your scenes ready…").foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                ForEach(model.scenes, id: \.name) { s in
                    SceneRow(scene: s, openCount: model.review.openCounts[s.name] ?? 0)
                        .tag(s.name)
                        .id(s.name)
                        .opacity(sceneListIsStale ? 0.5 : 1)
                }
                if sceneListIsStale {
                    Text("Scenes come back after the next good build.")
                        .font(StudioStyle.Fonts.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Comments") {
                commentsRow("Open", count: model.review.count(segment: .open), symbol: "circle", segment: .open)
                commentsRow("Ready for Review", count: model.review.readyForReviewCount, symbol: "checkmark.circle", segment: .review)
            }
            Section("Exports") {
                let outs = model.renders.recentOutputs(limit: 5)
                if outs.isEmpty {
                    Text("Nothing exported yet").foregroundStyle(.secondary)
                }
                ForEach(outs, id: \.self) { url in
                    Label(url.lastPathComponent, systemImage: url.pathExtension == "gif" ? "photo" : "film")
                        .lineLimit(1).truncationMode(.middle)
                        .contextMenu {
                            Button("Open") { NSWorkspace.shared.open(url) }
                            Button("Show in Finder") { SourceOpener.reveal(url) }
                        }
                        .help(url.path)
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// A failed build with no live preview: the list is the last good one.
    private var sceneListIsStale: Bool {
        if case .failed = model.build.phase, model.host.active == nil, !model.scenes.isEmpty { return true }
        return false
    }

    private var footer: some View {
        HStack {
            Menu {
                Button("Add a Scene…") {
                    // No scene template writer yet: point at the file-based path, which Studio already watches.
                    let dir = model.project.config.scenesDir ?? "your scenes folder"
                    model.ui.toast = "Scenes are Swift files. Add one to \(dir) and it shows up here when you save."
                }
                Button("New Launch Film…") { Task { await model.newLaunchFilm() } }
            } label: {
                Image(systemName: StudioStyle.Symbol.add)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add a scene or a launch film")
            Spacer()
        }
        .padding(.horizontal, StudioStyle.Space.m)
        .padding(.vertical, StudioStyle.Space.s)
        .overlay(alignment: .top) { StudioStyle.hairline.frame(height: 1) }
    }

    private func commentsRow(_ title: String, count: Int, symbol: String, segment: ReviewSegment) -> some View {
        Button {
            model.review.query = ReviewQuery(segment: segment)
            model.review.threadOpen = false
            model.ui.inspectorTab = .comments
            model.ui.showInspector = true
        } label: {
            Label(title, systemImage: symbol)
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .badge(count)
    }
}

struct SceneRow: View {
    var scene: SceneSummary
    var openCount: Int

    var body: some View {
        Label(scene.name, systemImage: StudioStyle.symbol(scene.kind))
            .badge(openCount)
            .help(help)
    }

    private var help: String {
        var parts: [String] = []
        if scene.hasProps { parts.append("Has editable content") }
        if scene.kind == .audio || scene.kind == .propsAudio { parts.append("Moves to the music") }
        if openCount > 0 { parts.append("\(openCount) open comment\(openCount == 1 ? "" : "s")") }
        return parts.joined(separator: ". ")
    }
}
