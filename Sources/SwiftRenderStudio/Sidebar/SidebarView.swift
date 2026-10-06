import SwiftUI
import SwiftRenderKit

// MARK: - Sidebar
//
// Scenes grouped by what you do with them — Templates (editable content), Music-driven,
// Films — each collapsible, with a filter field · Comments (Open, Ready for Review: each
// opens that segment) · Exports (recent files) · a + menu to add a scene or a launch film.
// Right-click a scene (Open, Open in Editor, Show in Finder, Copy Name, Duplicate, Move to
// Trash…), a section header (Collapse All / Expand All) or an export (Open, Show in Finder,
// Copy Path, Move to Trash…); see ContextMenus.

/// How the sidebar groups scenes: by what you can do with them, not how they're coded.
enum SceneCategory: String, CaseIterable, Identifiable {
    case templates, music, films
    var id: String { rawValue }

    init(_ s: SceneSummary) {
        if s.hasProps { self = .templates }
        else if s.kind == .audio || s.kind == .propsAudio { self = .music }
        else { self = .films }
    }

    var title: String {
        switch self {
        case .templates: return "Templates"
        case .music: return "Music-driven"
        case .films: return "Films"
        }
    }

    /// One icon per section, so a row's icon never needs decoding.
    var symbol: String {
        switch self {
        case .templates: return "slider.horizontal.3"
        case .music: return "waveform"
        case .films: return "film"
        }
    }

    var help: String {
        switch self {
        case .templates: return "Fill in your own words, colors and images in the Content tab"
        case .music: return "Move with the soundtrack"
        case .films: return "Finished scenes, edited in code"
        }
    }
}

struct SidebarView: View {
    @Bindable var model: ProjectModel
    @State private var filter = ""
    @State private var collapsed: Set<SceneCategory> = []

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
        // One continuous surface: the sidebar material would otherwise pick up the
        // picture and the timeline behind it and change shade at the timeline's edge.
        .background(StudioStyle.chrome)
    }

    private var list: some View {
        List(selection: Binding(get: { model.selectedScene }, set: { name in
            if let name { Task { await model.select(scene: name) } }
        })) {
            if model.scenes.isEmpty || sceneListIsStale {
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
                    } else {
                        Text("Scenes come back after the next good build.")
                            .font(StudioStyle.Fonts.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(SceneCategory.allCases) { category in
                let scenes = visibleScenes(in: category)
                if !scenes.isEmpty {
                    Section(isExpanded: expansion(category)) {
                        ForEach(scenes, id: \.name) { s in
                            SceneRow(scene: s, category: category, openCount: model.review.openCounts[s.name] ?? 0)
                                .tag(s.name)
                                .id(s.name)
                                .opacity(sceneListIsStale ? 0.5 : 1)
                                .studioContextMenu(ContextMenus.scene(s, model: model))
                        }
                    } header: {
                        HStack {
                            Text(category.title)
                            Spacer()
                            Text("\(scenes.count)").monospacedDigit().foregroundStyle(.tertiary)
                        }
                        .help(category.help)
                        .contentShape(Rectangle())
                        .studioContextMenu(sectionMenu)
                    }
                }
            }
            if !filter.isEmpty && SceneCategory.allCases.allSatisfy({ visibleScenes(in: $0).isEmpty }) {
                Section("Scenes") {
                    Text("No scenes match “\(filter)”").foregroundStyle(.secondary)
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
                        .studioContextMenu(ContextMenus.export(url, model: model))
                        .help(url.path)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .searchable(text: $filter, placement: .sidebar, prompt: "Filter scenes")
    }

    /// Section headers: Collapse All / Expand All (filtering shows every match, so both wait).
    private var sectionMenu: [StudioMenuEntry] {
        let shown = SceneCategory.allCases.filter { !visibleScenes(in: $0).isEmpty }
        return ContextMenus.section(collapseAll: { collapsed = Set(SceneCategory.allCases) },
                                    expandAll: { collapsed = [] },
                                    anyOpen: filter.isEmpty && shown.contains { !collapsed.contains($0) },
                                    anyClosed: filter.isEmpty && shown.contains { collapsed.contains($0) })
    }

    private func visibleScenes(in category: SceneCategory) -> [SceneSummary] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        return model.scenes.filter {
            SceneCategory($0) == category && (q.isEmpty || $0.name.localizedCaseInsensitiveContains(q))
        }
    }

    /// Sections start open; while filtering, every section with a match shows.
    private func expansion(_ c: SceneCategory) -> Binding<Bool> {
        Binding(get: { !filter.isEmpty || !collapsed.contains(c) },
                set: { open in if open { collapsed.remove(c) } else { collapsed.insert(c) } })
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
    var category: SceneCategory
    var openCount: Int

    var body: some View {
        Label(scene.name, systemImage: category.symbol)
            .badge(openCount)
            .help(help)
    }

    private var help: String {
        var parts: [String] = []
        if scene.hasProps { parts.append("Editable content in the Content tab") }
        if scene.kind == .audio || scene.kind == .propsAudio { parts.append("Moves with the music") }
        if openCount > 0 { parts.append("\(openCount) open comment\(openCount == 1 ? "" : "s")") }
        return parts.joined(separator: ". ")
    }
}
