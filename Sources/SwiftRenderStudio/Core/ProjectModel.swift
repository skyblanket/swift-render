import AppKit
import Foundation
import Observation
import SwiftRenderKit

// MARK: - Project model
//
// One per project window. Owns every controller and wires the hot-reload loop:
//
//   FileWatcher(Sources/, Plugins/, Package.swift, assets/, .swift-render/{reviews,knobs})
//     source/manifest → BuildController (debounced, one at a time, scratch .build/studio)
//       success → HostSupervisor.swap (blue/green) → PlaybackEngine.attach → re-request t
//     review → ReviewController.reload        knobs → setKnobs        asset → reopen
//
// UI-facing layout state lives in `StudioUIState` so views stay dumb.

/// What surrounds the picture in the viewer.
enum ViewerBackground: String, CaseIterable, Identifiable, Sendable {
    case automatic, black, gray, white
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .black: return "Black"
        case .gray: return "Gray"
        case .white: return "White"
        }
    }
}

enum AspectChoice: String, CaseIterable, Identifiable, Sendable {
    case landscape = "16:9", vertical = "9:16", square = "1:1"
    var id: String { rawValue }
    var size: CGSize {
        switch self {
        case .landscape: return CGSize(width: 1920, height: 1080)
        case .vertical: return CGSize(width: 1080, height: 1920)
        case .square: return CGSize(width: 1080, height: 1080)
        }
    }
}

/// How Studio was launched for this window (command line or Welcome).
struct LaunchOptions: Equatable, Sendable {
    var projectPath: URL?
    var scene: String?
    var at: Double?
    var fakeHost = false
    var snapshot: String?
    /// FakeHost only: crash when rendering this time (exercises the crash card).
    var fakeCrashAt: Double?
    /// FakeHost only: minimum milliseconds per frame (`--fake-render-ms`), so tests can
    /// queue requests behind an in-flight render without racing the machine's load.
    var fakeRenderMs: Double?
    /// Fake modes: simulated builds fail (and one runs right after launch).
    var fakeBuildFails = false
    /// Inspector tab to show first (`--tab knobs`), e.g. to snapshot a tab.
    var tab: InspectorTab?
    /// Snapshot mode: play this many seconds before capturing (prints playback stats).
    var playFor: Double?
    /// `--knob key=value` (repeatable): live knob overrides applied once the scene opens.
    var knobs: [String: String] = [:]
    /// `--props file.json`: props applied once the scene opens (errors land in the Props tab).
    var propsFile: String?
    /// `--check`: run the host `check` once the scene opens (Info tab contact sheet).
    var runCheck = false
    /// Run as a protocol-speaking fake host on stdio (`FakeServe`), not as an app.
    var fakeServe = false
    /// Snapshot mode: export with this preset first (`--render preview`), captured mid-progress
    /// or, with `--render-wait done`, once finished.
    var renderPreset: RenderPreset?
    var renderWaitDone = false
    /// Snapshot mode: In/Out set before rendering (`--in-out 2:8`).
    var inOut: ClosedRange<Double>?
    /// Snapshot mode: draw a sheet/popover over the window (`--show render-sheet|renders`).
    var show: String?
    /// Fake host in a child process through the real `HostClient` (implies simulated builds).
    var fakeProcessHost = false
    /// Review UI snapshots: `--comment <id|first|N>`, `--compare <split|toggle|sideBySide|difference>`,
    /// `--draft x,y,w,h|point:x,y`, `--draft-text "…"` (see `applyReviewLaunchOptions`).
    var commentSelection: String?
    var compareMode: CompareMode?
    var draftRegion: String?
    var draftText: String?
    /// Snapshot mode: replay this recorded `claude` stream-json into the agent panel first.
    var agentReplay: String?
    /// Snapshot mode: capture with the Ask Claude sheet open.
    var askSheet = false
    /// Snapshot mode: run "New Launch Film…" (scan, open AppleLaunch with the props) first.
    var newLaunchFilm = false
    /// `--appearance light|dark|system`: overrides View › Appearance for this process.
    var appearance: StudioAppearance?

    static func parse(_ argv: [String]) -> LaunchOptions {
        var o = LaunchOptions()
        var i = 0
        while i < argv.count {
            let a = argv[i], v = i + 1 < argv.count ? argv[i + 1] : nil
            switch a {
            case "--scene": o.scene = v; i += 2
            case "--at", "--t": o.at = v.flatMap(Double.init); i += 2
            case "--fake-host": o.fakeHost = true; i += 1
            case "--fake-serve": o.fakeServe = true; i += 1
            case "--fake-process-host": o.fakeProcessHost = true; i += 1
            case "--fake-build-fail": o.fakeBuildFails = true; i += 1
            case "--snapshot": o.snapshot = v; i += 2
            case "--play-for": o.playFor = v.flatMap(Double.init); i += 2
            case "--tab": o.tab = v.flatMap(InspectorTab.init(rawValue:)); i += 2
            case "--knob":
                if let v, let eq = v.firstIndex(of: "=") { o.knobs[String(v[..<eq])] = String(v[v.index(after: eq)...]) }
                i += 2
            case "--props": o.propsFile = v; i += 2
            case "--check": o.runCheck = true; i += 1
            case "--fake-crash-at": o.fakeCrashAt = v.flatMap(Double.init); i += 2
            case "--fake-render-ms": o.fakeRenderMs = v.flatMap(Double.init); i += 2
            case "--comment": o.commentSelection = v; i += 2
            case "--compare": o.compareMode = v.flatMap(CompareMode.init(rawValue:)); i += 2
            case "--draft": o.draftRegion = v; i += 2
            case "--draft-text": o.draftText = v; i += 2
            case "--agent-replay": o.agentReplay = v; i += 2
            case "--ask-sheet": o.askSheet = true; i += 1
            case "--new-launch-film": o.newLaunchFilm = true; i += 1
            case "--appearance": o.appearance = v.flatMap(StudioAppearance.init(rawValue:)); i += 2
            case "--render": o.renderPreset = v.flatMap(RenderPreset.init(rawValue:)); i += 2
            case "--render-wait": o.renderWaitDone = v == "done"; i += 2
            case "--show": o.show = v; i += 2
            case "--in-out":
                let p = (v ?? "").split(separator: ":").compactMap { Double($0) }
                if p.count == 2, p[0] < p[1] { o.inOut = p[0]...p[1] }
                i += 2
            case "--project": o.projectPath = v.map { URL(fileURLWithPath: $0, isDirectory: true) }; i += 2
            default:
                // macOS passes -NSDocumentRevisionsDebugMode etc.; positional = project.
                if !a.hasPrefix("-"), o.projectPath == nil {
                    o.projectPath = URL(fileURLWithPath: a, isDirectory: true)
                    i += 1
                } else if a.hasPrefix("-"), let v, !v.hasPrefix("-") { i += 2 } else { i += 1 }
            }
        }
        return o
    }
}

@MainActor @Observable
final class StudioUIState {
    var showInspector = true
    var showSidebar = true
    /// Hidden while idle; slides up when a run starts (unless closed during that run).
    var showAgentPanel = false
    /// The person closed the panel during the current run: leave it closed.
    var agentPanelClosed = false
    /// View › Show Playback Statistics: a small overlay in the viewer corner.
    var showStats = UserDefaults.standard.bool(forKey: "viewer.showStats")
    /// View › Background: what surrounds the picture.
    var viewerBackground = ViewerBackground(rawValue: UserDefaults.standard.string(forKey: "viewer.background") ?? "") ?? .automatic
    var inspectorTab: InspectorTab = .comments
    var guides: GuideMode = .off
    var zoom: ViewerZoom = .fit
    /// nil = compare off.
    var compare: CompareMode?
    var regionArmed = false
    var showAskSheet = false
    var showRenderSheet = false
    var showBuildPopover = false
    var showRenderActivity = false
    var viewport = TimelineViewport()
    var selectedClipID: String?
    /// Transient toast in the viewer ("Saved knobs", "No source for this clip").
    var toast: String?
}

@MainActor @Observable
final class ProjectModel {
    let project: Project
    let options: LaunchOptions
    private(set) var scenes: [SceneSummary] = []
    private(set) var selectedScene: String?
    private(set) var info: SceneInfo?
    var aspect: AspectChoice = .landscape
    /// Live knob values (may differ from `.swift-render/knobs/<Scene>.json`).
    var knobValues: [String: KnobValue] = [:]
    var propsJSON: String?
    /// Layout state (a `var` only so SwiftUI can form bindings through it).
    var ui = StudioUIState()

    let build: BuildController
    let host: HostSupervisor
    let playback: PlaybackEngine
    let review: ReviewController
    let agent: AgentController
    let renders: RenderQueue
    /// Knobs / Props / Info tab state.
    @ObservationIgnored private(set) lazy var inspector = InspectorController(model: self)

    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var started = false

    var isFake: Bool { options.fakeHost || options.fakeProcessHost }
    var title: String { project.root.lastPathComponent }

    init(root: URL, options: LaunchOptions = LaunchOptions()) {
        let project = Project.open(root)
        self.project = project
        self.options = options
        let fake = options.fakeHost || options.fakeProcessHost
        let failBuilds = options.fakeBuildFails
        build = BuildController(project: project, runner: fake ? SimulatedBuild.runner(fail: { failBuilds }) : nil)
        let factory: HostSupervisor.Factory
        if options.fakeProcessHost {
            // This very binary, as `--fake-serve`, behind the real client.
            let me = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            let args = ["--fake-serve"] + (options.fakeCrashAt.map { ["--fake-crash-at", "\($0)"] } ?? [])
            factory = { _, _ in
                try HostClient(executable: me, project: project,
                               environment: HostClient.hostEnvironment(project: project), arguments: args)
            }
        } else if options.fakeHost {
            factory = { _, gen in
                var o = FakeHostClient.Options()
                o.generation = gen
                o.crashAt = options.fakeCrashAt
                o.projectRoot = project.root
                return FakeHostClient(options: o)
            }
        } else {
            factory = HostSupervisor.realFactory(project: project)
        }
        host = HostSupervisor(project: project, makeHost: factory)
        // Settings › Playback.
        let defaults = UserDefaults.standard
        let budgetMB = defaults.object(forKey: "cacheBudgetMB") == nil ? 1024 : max(256, defaults.integer(forKey: "cacheBudgetMB"))
        playback = PlaybackEngine(cache: FrameCache(budgetBytes: budgetMB << 20))
        playback.quality = defaults.string(forKey: "playbackQuality").flatMap(PlaybackQuality.init(rawValue:)) ?? .auto
        review = ReviewController(project: project)
        agent = AgentController(project: project)
        renders = RenderQueue(project: project)
        wire()
    }

    convenience init(root: URL) { self.init(root: root, options: LaunchOptions()) }

    private func wire() {
        build.onSuccess = { [weak self] exe, gen in
            guard let self else { return }
            Task { await self.hostBuilt(exe, generation: gen) }
        }
        host.currentTime = { [weak self] in self?.playback.t ?? 0 }
        host.warmWidth = { [weak self] in self?.playback.displayWidth ?? 960 }
        host.onActiveHost = { [weak self] h, info, warm in
            guard let self else { return }
            if let h, h !== self.host.active { return }        // a retired host's late reply
            if h == nil { self.playback.pause() }
            if let info { self.adopt(info) }
            if !self.host.scenes.isEmpty { self.scenes = self.host.scenes }
            self.playback.attach(host: h, info: info, warmFrame: warm)
        }
        host.onPoison = { [weak self] f in self?.playback.poisoned.insert(f) }
        host.onPoisonCleared = { [weak self] in self?.playback.poisoned = [] }
        host.onEvent = { [weak self] msg in
            guard let self else { return }
            switch msg.event {
            case "info": if let i = msg.info { self.adopt(i) }
            case "audio":
                // The real host opens before the score is synthesized; the envelope and
                // WAV arrive here, not in a follow-up `info`.
                if var i = self.info {
                    if let p = msg.audioPath { i.audioPath = p }
                    if let l = msg.loudness { i.loudness = l }
                    self.adopt(i)
                }
                if let p = msg.audioPath { self.playback.audio.load(URL(fileURLWithPath: p), at: self.playback.t) }
                // Audio-reactive frames rendered so far used a silent track.
                if let k = self.info?.kind, k == .audio || k == .propsAudio { self.playback.invalidate() }
            default: break
            }
        }
        playback.onHang = { [weak self] t, h in self?.host.reportHang(at: t, host: h) }
        renders.inputs = { [weak self] scene in
            guard let self else { return RenderInputs() }
            let current = scene == self.selectedScene
            let summary = self.scenes.first { $0.name == scene }
            return RenderInputs(knobs: current ? self.knobValues : [:],
                                propsJSON: current && summary?.hasProps == true ? self.propsJSON : nil,
                                debugExecutable: self.isFake ? nil : self.build.lastGoodExecutable,
                                hasSoundtrack: summary?.hasSoundtrack ?? false,
                                duration: current ? self.info?.duration : summary?.defaultDuration)
        }
        review.onChange = { [weak self] comments in
            self?.playback.commentMarks = comments.map { (id: $0.id, t: $0.t, end: $0.end) }
        }
        review.captureStill = { [weak self] t, url in
            guard let host = self?.host.active else { throw ReviewError.io("no render host") }
            _ = try await host.call(.still, HostParams(t: t, path: url.path))
        }
        review.frameContext = { [weak self] in
            guard let self else { return ReviewFrameContext() }
            return ReviewFrameContext(info: self.info, knobs: self.knobValues, propsJSON: self.propsJSON,
                                      aspect: self.aspect == .landscape ? nil : self.aspect.rawValue,
                                      generation: self.host.generation)
        }
        // While an agent edits, its half-done states don't shout, and a multi-file edit is one build.
        agent.onRunningChanged = { [weak self] running in
            guard let self else { return }
            if running {
                self.ui.agentPanelClosed = false
                self.ui.showAgentPanel = true
            }
            self.build.agentEditing = running
            self.watcher?.debounce = .milliseconds(running ? 600 : 150)
        }
        agent.onReviewsChanged = { [weak self] in self?.review.reload() }
    }

    // MARK: Lifecycle

    /// Initial build (or fake host), scene selection, file watching.
    func start() async {
        guard !started else { return }
        started = true
        // `--scene X`: the same per-scene state a sidebar pick loads (its saved knobs
        // included — the host loads them too, so model and viewer agree).
        if let scene = options.scene { loadSceneState(scene) }
        if let tab = options.tab { ui.inspectorTab = tab }
        if let at = options.at { playback.seek(at) }
        if options.scene == nil { review.load(scene: nil) }
        applyReviewLaunchOptions()
        startWatching()
        if isFake {
            await host.start(URL(fileURLWithPath: "/fake-host"), generation: 1, open: openParams())
            if selectedScene == nil, let first = host.scenes.first?.name { await select(scene: first) }
            if options.fakeBuildFails { build.requestBuild(.manual) }
        } else {
            build.requestBuild(.initial)
        }
    }

    func shutdown() async {
        watcher?.stop()
        watcher = nil
        build.cancel()
        agent.stop()
        await renders.shutdown()
        await host.shutdown()
    }

    private func startWatching() {
        let w = FileWatcher(root: project.root) { [weak self] changes in
            Task { @MainActor in self?.handle(changes) }
        }
        w.start()
        watcher = w
    }

    func handle(_ changes: [FileWatcher.Change]) {
        for c in changes {
            switch c.kind {
            case .source, .manifest:
                build.requestBuild(.sourceChange(c.paths))
            case .asset:
                Task { _ = try? await host.reopen(openParams()); playback.invalidate() }
            case .review:
                review.reload()
            case .knobs:
                guard let scene = selectedScene,
                      c.paths.contains(where: { $0.hasSuffix("/\(scene).json") }) else { continue }
                // Not a time window after our own save (an agent's set_knobs landing in it was
                // dropped, then overwritten by the next save): compare contents instead. Our
                // own write reads back as the live set; anything else is applied.
                let values = KnobFile.load(project.knobsURL(scene: scene))
                guard values != knobValues else { continue }
                Task { await setKnobs(values, dragging: false, replacing: true) }
            }
        }
    }

    /// A build succeeded. The supervisor serializes launches (a build that lands while the
    /// previous host is still starting queues behind it) and clears the poison set only when
    /// the new build actually goes live — a failed swap keeps the old build and its poison.
    private func hostBuilt(_ exe: URL, generation gen: Int) async {
        if !host.hasStarted {
            await host.start(exe, generation: gen, open: openParams())
        } else {
            await host.swap(to: exe, generation: gen)
        }
        if selectedScene == nil, let first = host.scenes.first?.name { await select(scene: first) }
    }

    // MARK: Scenes

    func openParams() -> HostParams {
        let size = aspect.size
        return HostParams(scene: selectedScene, width: Int(size.width), height: Int(size.height),
                          propsJSON: propsJSON, knobs: knobValues.isEmpty ? nil : knobValues,
                          binaryFrames: true)
    }

    func select(scene: String) async {
        guard scene != selectedScene || info == nil else { return }
        playback.pause()
        loadSceneState(scene)
        do {
            if let info = try await host.reopen(openParams()) {
                adopt(info)
                ui.viewport.fit(info.duration)
            }
        } catch {
            ui.toast = "Couldn't open \(scene). \(HostSupervisor.describe(error))"
        }
    }

    /// Per-scene state, before the host opens it: default props, the saved knob file, comments.
    private func loadSceneState(_ scene: String) {
        selectedScene = scene
        propsJSON = nil
        knobValues = KnobFile.load(project.knobsURL(scene: scene))
        review.load(scene: scene)
        ui.selectedClipID = nil
    }

    func setAspect(_ a: AspectChoice) async {
        guard a != aspect else { return }
        aspect = a
        _ = try? await host.reopen(openParams())
    }

    private func adopt(_ i: SceneInfo) {
        let first = info?.name != i.name
        // Showing the whole scene before a length change: keep showing the whole scene.
        let wasFit = info.map { abs(ui.viewport.pxPerSecond - ui.viewport.fitPxPerSecond) < 1e-6 && $0.duration != i.duration } ?? false
        info = i
        if propsJSON == nil { propsJSON = i.propsJSON }
        ui.viewport.duration = i.duration
        ui.viewport.fps = i.fps
        // A props-driven length change reaches the transport too, not just the timeline.
        if !first { playback.adopt(i) }
        if first || wasFit { ui.viewport.fit(i.duration) }
        // `--knob` / `--props` / `--check` apply once the first scene is open, whether or
        // not an inspector tab is on screen (runs once).
        if first, inspector.hasLaunchWork { Task { await inspector.sceneOpened() } }
    }

    // MARK: Knobs / props

    /// `dragging`: skip the structure re-probe (`reprobe: false`) while a slider moves.
    /// `replacing`: `values` is the whole live set, else it's merged in. Either way the
    /// host gets the complete set: `setKnobs` treats missing keys as back-to-default.
    func setKnobs(_ values: [String: KnobValue], dragging: Bool, replacing: Bool = false) async {
        if replacing { knobValues = values } else { knobValues.merge(values) { $1 } }
        let info = try? await host.apply(.setKnobs, HostParams(knobs: knobValues, reprobe: !dragging))
        if !dragging, let info { adopt(info) }      // a re-probe may have found knobs behind the change
        playback.invalidate()
    }

    func saveKnobs() {
        guard let scene = selectedScene else { return }
        try? KnobFile.save(knobValues, to: project.knobsURL(scene: scene))
    }

    /// nil = the scene's `defaultProps`. Props may change the duration, so the new info is adopted.
    func setProps(_ json: String?) async throws {
        let info = try await host.apply(.setProps, HostParams(propsJSON: json))
        propsJSON = json ?? info?.propsJSON
        if let info { adopt(info) }
        playback.invalidate()
    }

    /// "New Launch Film…": the project CLI scans the codebase (`launch --no-render`, which keeps
    /// an already-edited `.swift-render/launch/<Name>.json`), then AppleLaunch opens with those props.
    func newLaunchFilm() async {
        guard !isFake, let exe = build.lastGoodExecutable else {
            ui.toast = "A launch film needs one good build first"
            return
        }
        guard scenes.contains(where: { $0.name == "AppleLaunch" }) else {
            ui.toast = "This project has no AppleLaunch scene yet (it comes with swift-render 0.9 and later)"
            return
        }
        let target = Self.launchTarget(project: project, scenes: scenes)
        let result: Result<String, Error>
        if let saved = target.props, let json = try? String(contentsOf: saved, encoding: .utf8) {
            // An `init` scaffold: the app was scanned into this file (asset paths under assets/).
            result = .success(json)
        } else {
            ui.toast = "Reading \(target.root.lastPathComponent) for your launch film…"
            let root = target.root, cwd = project.root
            let out = project.cacheDir.appendingPathComponent("launch-props.json")
            result = await Task.detached { () -> Result<String, Error> in
                do {
                    try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let r = try ProcessRunner.run(exe.path, ["launch", root.path, "--no-render", "--props-out", out.path], cwd: cwd)
                    guard r.status == 0 else { throw LaunchScanFailure(message: r.stderr.split(separator: "\n").last.map(String.init) ?? "launch failed") }
                    let json = try String(contentsOf: out, encoding: .utf8)
                    // Scanned outside this package: its relative art paths mean nothing to this host.
                    return .success(root == cwd ? json : Self.absolutizingAssets(json, base: root))
                } catch { return .failure(error) }
            }.value
        }
        switch result {
        case .success(let json):
            await select(scene: "AppleLaunch")
            do {
                try await setProps(json)
                ui.toast = "Your launch film is ready. Edit its words in the Content tab."
            } catch {
                ui.toast = "Couldn't apply the launch film's content. \(HostSupervisor.describe(error))"
            }
        case .failure(let error):
            ui.toast = "Couldn't read the project for a launch film. \(error)"
        }
    }

    /// What "New Launch Film…" scans. A `swift-render init` scaffold (product "launch") is a
    /// Launch/ package inside the app: the film is about the app in the parent folder, and
    /// `init` already scanned it into `.swift-render/launch/<App>Launch.json` (its own scene's
    /// name), with the art copied into assets/. Anywhere else: the project itself.
    nonisolated static func launchTarget(project: Project, scenes: [SceneSummary]) -> (root: URL, props: URL?) {
        guard project.config.product == "launch" else { return (project.root, nil) }
        let fm = FileManager.default
        let dir = project.root.appendingPathComponent(".swift-render/launch", isDirectory: true)
        for s in scenes where s.name != "AppleLaunch" {
            let f = dir.appendingPathComponent("\(s.name).json")
            if fm.fileExists(atPath: f.path) { return (project.root.deletingLastPathComponent(), f) }
        }
        let parent = project.root.deletingLastPathComponent()
        let entries = (try? fm.contentsOfDirectory(atPath: parent.path)) ?? []
        let isApp = entries.contains { $0 == "Package.swift" || $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
        return (isApp ? parent : project.root, nil)
    }

    /// Launch props with relative icon/screenshot paths made absolute against `base`.
    nonisolated static func absolutizingAssets(_ json: String, base: URL) -> String {
        guard var props = try? JSONDecoder().decode(LaunchProps.self, from: Data(json.utf8)) else { return json }
        func abs(_ p: String) -> String {
            p.isEmpty || p.hasPrefix("/") || p.hasPrefix("~") ? p : base.appendingPathComponent(p).standardizedFileURL.path
        }
        if let icon = props.icon {
            props.icon?.path = abs(icon.path)
            props.icon?.darkPath = icon.darkPath.map(abs)
        }
        for i in props.screenshots.indices { props.screenshots[i].path = abs(props.screenshots[i].path) }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(props)).map { String(decoding: $0, as: UTF8.self) } ?? json
    }

    // MARK: Actions

    func perform(_ a: StudioAction) {
        let p = playback
        switch a {
        case .playPause: p.toggle()
        case .shuttle(let k): p.shuttle(k)
        case .stepFrames(let n): p.step(frames: n)
        case .stepSeconds(let s): p.seek(p.t + s, precise: true)
        case .jumpEdit(let next): p.jumpToEdit(next: next)
        case .home: p.seek(0, precise: true)
        case .end: p.seek(p.duration, precise: true)
        case .setIn: p.setIn()
        case .setOut: p.setOut()
        case .goIn: if let io = p.inOut { p.seek(io.lowerBound, precise: true) }
        case .goOut: if let io = p.inOut { p.seek(io.upperBound, precise: true) }
        case .clearInOut: p.clearInOut()
        case .loopInOut:
            p.loop.toggle()
            if p.loop, let io = p.inOut { p.seek(io.lowerBound, precise: true); p.play() }
        case .newComment:
            p.pause()
            let io = p.inOut
            review.beginComment(t: io?.lowerBound ?? p.t, end: io?.upperBound)
            ui.inspectorTab = .comments
            ui.showInspector = true
        case .armRegion: ui.regionArmed.toggle()
        case .selectComment(let next):
            if let t = review.selectAdjacent(next: next, from: p.t) {
                p.seek(t, precise: true)
                if review.threadOpen, let id = review.selection { review.open(id) }
            }
        case .toggleCompare: ui.compare = ui.compare == nil ? .split : nil
        case .cycleCompare: ui.compare = (ui.compare ?? .split).next
        case .cycleGuides: ui.guides = ui.guides.next
        case .toggleZoomFit: ui.zoom = ui.zoom == .fit ? .p100 : .fit
        case .timelineZoomIn: ui.viewport.zoom(by: 1.5, around: ui.viewport.x(p.t))
        case .timelineZoomOut: ui.viewport.zoom(by: 1 / 1.5, around: ui.viewport.x(p.t))
        case .timelineZoomFit: ui.viewport.fit(p.duration)
        case .build: build.requestBuild(.manual)
        case .render:
            if let scene = selectedScene {
                renders.enqueue(scene: scene, preset: renders.lastPreset, range: nil,
                                build: renders.lastPreset.prefersRelease ? .optimized : .currentDebug, knobs: .useLive)
                ui.showRenderActivity = true
            }
        case .renderSheet: ui.showRenderSheet = true
        case .askAgent: ui.showAskSheet = true
        case .stop:
            if agent.isRunning { agent.stop() } else if build.isBuilding { build.cancel() }
            else if let j = renders.active { renders.cancel(j.id) }
        case .openSource: openSource()
        case .inspectorTab(let t): ui.inspectorTab = t; ui.showInspector = true
        case .toggleInspector: ui.showInspector.toggle()
        case .toggleSidebar: ui.showSidebar.toggle()
        case .toggleAgentPanel:
            ui.showAgentPanel.toggle()
            if !ui.showAgentPanel, agent.isRunning { ui.agentPanelClosed = true }
        case .toggleStats:
            ui.showStats.toggle()
            UserDefaults.standard.set(ui.showStats, forKey: "viewer.showStats")
        case .cancel:
            if ui.regionArmed { ui.regionArmed = false }
            else if review.draft != nil { review.draft = nil }
            else if ui.compare != nil { ui.compare = nil }
            else { ui.showBuildPopover = false; ui.showRenderActivity = false }
        }
    }

    /// ⌘⇧O: the selected clip's source, else the scene file.
    func openSource() {
        if let id = ui.selectedClipID, let src = info?.clips.first(where: { $0.id == id })?.source {
            SourceOpener.open(src)
        } else if let path = info?.sourcePath {
            SourceOpener.open(file: path, line: 1)
        } else {
            ui.toast = "This scene has no source file to open"
        }
    }
}

/// `launch --no-render` exited non-zero; the message is its last stderr line.
private struct LaunchScanFailure: Error, CustomStringConvertible {
    var message: String
    var description: String { message }
}
