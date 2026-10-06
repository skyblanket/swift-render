import AppKit
import SwiftUI

// MARK: - Project window
//
// 2-column NavigationSplitView (sidebar | detail) + trailing `.inspector`, which reads
// as three columns but lets the viewer — not a fixed-width list column — take extra
// width. Detail = VSplitView { viewer + transport, timeline, agent panel }.

/// One model per project root for the process (WindowGroup may re-create views).
@MainActor
final class ProjectStore {
    static let shared = ProjectStore()
    private var models: [URL: ProjectModel] = [:]

    func model(for root: URL, options: LaunchOptions? = nil) -> ProjectModel {
        let key = root.standardizedFileURL
        if let m = models[key] { return m }
        let m = ProjectModel(root: key, options: options ?? StudioLaunch.options)
        models[key] = m
        Recents.add(key)
        return m
    }

    func close(_ root: URL) async {
        let key = root.standardizedFileURL
        guard let m = models.removeValue(forKey: key) else { return }
        await m.shutdown()
    }

    var allModels: [ProjectModel] { Array(models.values) }

    func shutdownAll() async {
        let all = models.values
        models = [:]
        for m in all { await m.shutdown() }
    }
}

/// Command-line options for this process (set once in `StudioMain`).
@MainActor
enum StudioLaunch {
    static var options = LaunchOptions()
}

struct ProjectWindow: View {
    let root: URL
    var body: some View {
        ProjectWindowContent(model: ProjectStore.shared.model(for: root))
            .onDisappear { Task { await ProjectStore.shared.close(root) } }
    }
}

struct ProjectWindowContent: View {
    @Bindable var model: ProjectModel
    @State private var router: KeyRouter?
    @AppStorage(StudioAppearance.key) private var appearance = StudioAppearance.fallback.rawValue

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { model.ui.showSidebar ? .all : .detailOnly },
            set: { model.ui.showSidebar = $0 != .detailOnly })) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 320)
        } detail: {
            DetailSplit(model: model)
        }
        .inspector(isPresented: $model.ui.showInspector) {
            InspectorView(model: model)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 440)
        }
        .toolbar { StudioToolbar(model: model) }
        // The title is the scene switcher.
        .navigationTitle(model.selectedScene ?? model.title)
        .toolbarTitleMenu { SceneSwitcherMenu(model: model) }
        .sheet(isPresented: $model.ui.showAskSheet) { AskAgentSheet(model: model) }
        .sheet(isPresented: $model.ui.showRenderSheet) { RenderSheet(model: model) }
        .focusedSceneValue(\.project, model)
        .background(WindowAccessor { window in
            // Snapshots never take keys (the window draws as key but must not act on typing).
            if !StudioStyle.isSnapshot {
                if router == nil { router = KeyRouter(model: model) }
                router?.install(window: window)
            }
            // The project folder (often a worktree name) lives in the title's tooltip, not under it.
            window.representedURL = model.project.root
        })
        .task { await model.start() }
        .onDisappear { router?.uninstall() }
        .preferredColorScheme(scheme)
    }

    private var scheme: ColorScheme? {
        if let a = model.options.appearance { return a.colorScheme }
        return (StudioAppearance(rawValue: appearance) ?? StudioAppearance.fallback).colorScheme
    }
}

/// Scenes by name, for the window title menu.
struct SceneSwitcherMenu: View {
    let model: ProjectModel

    var body: some View {
        ForEach(model.scenes, id: \.name) { s in
            Button { Task { await model.select(scene: s.name) } } label: {
                Label(s.name, systemImage: StudioStyle.symbol(s.kind))
            }
        }
    }
}

/// Viewer + transport over timeline over the Claude panel. A hand-rolled split (NSSplitView
/// via VSplitView ignores ideal heights). The timeline fits its lanes until it is dragged;
/// double-click the divider to fit it again.
struct DetailSplit: View {
    @Bindable var model: ProjectModel
    /// 0 = fit the lanes.
    @AppStorage("layout.timelineHeightManual") private var timelineHeight = 0.0
    @AppStorage("layout.claudePanelHeight") private var agentHeight = 200.0

    private static let timelineRange: ClosedRange<Double> = 140...560

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                ViewerView(model: model)
                TransportBar(model: model)
            }
            .frame(minHeight: 260, maxHeight: .infinity)
            SplitHandle(height: Binding(get: { effectiveTimelineHeight }, set: { timelineHeight = $0 }),
                        range: Self.timelineRange, onReset: { timelineHeight = 0 })
            TimelineView(model: model)
                .frame(height: effectiveTimelineHeight)
            if model.ui.showAgentPanel {
                SplitHandle(height: $agentHeight, range: 120...420)
                AgentPanel(model: model)
                    .frame(height: agentHeight)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: model.ui.showAgentPanel)
        .background(StudioStyle.chrome)
    }

    private var effectiveTimelineHeight: Double {
        if timelineHeight > 0 { return min(Self.timelineRange.upperBound, max(Self.timelineRange.lowerBound, timelineHeight)) }
        let content = Double(TimelineLayout(info: model.info).contentHeight + TimelineLayout.rulerHeight + TimelineLayout.scrollerHeight)
        return min(Self.timelineRange.upperBound, max(Self.timelineRange.lowerBound, content + 2))
    }
}

/// A hairline with a 7 pt grab area; dragging up grows the pane below it.
struct SplitHandle: View {
    @Binding var height: Double
    var range: ClosedRange<Double>
    var onReset: (() -> Void)? = nil
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(StudioStyle.hairline)
            .frame(height: 1)
            .overlay {
                Color.clear
                    .frame(height: 7)
                    .contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { g in
                            if start == nil { start = height }
                            height = min(range.upperBound, max(range.lowerBound, start! - g.translation.height))
                        }
                        .onEnded { _ in start = nil })
                    .onTapGesture(count: 2) { onReset?() }
            }
            .zIndex(1)
    }
}

/// Reports the hosting NSWindow once the view is in one.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = AccessorView()
        v.onWindow = onWindow
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {}

    private final class AccessorView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let w = window { DispatchQueue.main.async { self.onWindow?(w) } }
        }
    }
}

/// Recently opened projects (Welcome window).
enum Recents {
    static let key = "recentProjects"

    static var all: [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func add(_ url: URL) {
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        list.removeAll { $0 == url.path }
        list.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(10)), forKey: key)
    }
}
