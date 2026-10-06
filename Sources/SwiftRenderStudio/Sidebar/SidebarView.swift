import SwiftUI
import SwiftRenderKit

// MARK: - Sidebar
//
// SCENES (kind icon, ~ audio-reactive, {} props, open-comment badge) · REVIEW
// (open / in progress) · RENDERS (recent outputs) · new scene / launch film.

struct SidebarView: View {
    @Bindable var model: ProjectModel

    var body: some View {
        List(selection: Binding(get: { model.selectedScene }, set: { name in
            if let name { Task { await model.select(scene: name) } }
        })) {
            Section("Scenes") {
                if model.scenes.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(model.build.isBuilding ? "Building…" : "Waiting for host…").foregroundStyle(.secondary)
                    }
                }
                ForEach(model.scenes, id: \.name) { s in
                    SceneRow(scene: s, openCount: model.review.openCounts[s.name] ?? 0)
                        .tag(s.name)
                }
            }
            Section("Review") {
                reviewRow("Open", count: model.review.openCount, symbol: "circle", color: StudioStyle.color(.open)) {
                    model.review.filter = .open
                }
                reviewRow("In progress", count: model.review.inProgressCount, symbol: "circle.lefthalf.filled",
                          color: StudioStyle.color(.inProgress)) {
                    model.review.filter = .agent
                }
            }
            Section("Renders") {
                let outs = model.renders.recentOutputs(limit: 5)
                if outs.isEmpty {
                    Text("No renders yet").foregroundStyle(.tertiary)
                }
                ForEach(outs, id: \.self) { url in
                    Label(url.lastPathComponent, systemImage: "film.stack")
                        .lineLimit(1).truncationMode(.middle)
                        .contextMenu { Button("Reveal in Finder") { SourceOpener.reveal(url) } }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Divider()
                Button { model.ui.toast = "New scene — coming with the launch kit" } label: {
                    Label("New scene", systemImage: "plus")
                }
                Button { model.ui.toast = "New launch film — runs `\(model.project.config.product) launch`" } label: {
                    Label("Launch film from codebase…", systemImage: "sparkles.tv")
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    private func reviewRow(_ title: String, count: Int, symbol: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: { action(); model.ui.inspectorTab = .comments; model.ui.showInspector = true }) {
            HStack {
                Label { Text(title) } icon: { Image(systemName: symbol).foregroundStyle(color) }
                Spacer()
                if count > 0 { Text("\(count)").monospacedDigit().foregroundStyle(.secondary) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SceneRow: View {
    var scene: SceneSummary
    var openCount: Int

    var body: some View {
        HStack(spacing: 6) {
            Label(scene.name, systemImage: StudioStyle.symbol(scene.kind))
            Spacer(minLength: 4)
            if scene.kind == .audio || scene.kind == .propsAudio {
                Text("~").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
                    .help("Audio-reactive")
            }
            if scene.hasProps {
                Text("{}").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
                    .help("Props scene")
            }
            if openCount > 0 {
                Text("\(openCount)")
                    .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(StudioStyle.color(.open).opacity(0.25), in: Capsule())
                    .help("\(openCount) open comment\(openCount == 1 ? "" : "s")")
            }
        }
    }
}
