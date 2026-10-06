import Foundation
import Observation
import SwiftRenderKit

// MARK: - Build controller
//
// One `swift build --product <p> --scratch-path <root>/.build/studio` at a time.
// The separate scratch path keeps Studio off the lock of the user's terminal builds;
// the agent is told to use the same path so its builds are usually no-ops.
// A change that lands mid-build sets `pendingRebuild` and exactly one more build
// runs afterwards. A successful build bumps `generation` and calls `onSuccess`,
// which swaps the render host.

/// Studio's view of a build event (Kit's `BuildResult` has no public init, and tests
/// and the simulated runner need to make these).
enum BuildUpdate: Sendable {
    struct Result: Sendable {
        var success: Bool
        var seconds: Double
        var diagnostics: [CompilerDiagnostic]
        var log: String
        var executable: URL?
        var errors: [CompilerDiagnostic] { diagnostics.filter { $0.severity == .error } }
    }
    case progress(String)
    case waitingForLock
    case diagnostic(CompilerDiagnostic)
    case finished(Result)

    init(_ e: BuildEvent) {
        switch e {
        case .progress(let s): self = .progress(s)
        case .waitingForLock: self = .waitingForLock
        case .diagnostic(let d): self = .diagnostic(d)
        case .finished(let r):
            self = .finished(Result(success: r.success, seconds: r.seconds, diagnostics: r.diagnostics,
                                    log: r.log, executable: r.executable))
        }
    }
}

enum BuildReason: Equatable, Sendable {
    case initial
    case manual
    case sourceChange([String])
    case agent
}

@MainActor @Observable
final class BuildController {
    enum Phase: Equatable {
        case idle
        case waitingForLock
        /// Latest progress line, e.g. "[12/40] Compiling SwiftRender NeverHeard.swift".
        case building(String)
        case succeeded(seconds: Double, at: Date)
        case failed([CompilerDiagnostic], log: String)
    }

    /// Swappable build runner (tests and `--fake-host` use a simulated one).
    typealias Runner = @Sendable (_ project: Project, _ product: String, _ scratch: URL)
        -> (events: AsyncStream<BuildUpdate>, cancel: @Sendable () -> Void)

    let project: Project
    let product: String
    let scratchPath: URL
    private(set) var phase: Phase = .idle
    /// Count of successful builds this session (the host generation they produced).
    private(set) var generation = 0
    private(set) var lastGoodExecutable: URL?
    /// Diagnostics of the running or last build (errors and warnings).
    private(set) var diagnostics: [CompilerDiagnostic] = []
    private(set) var log = ""
    /// Parsed from "[done/total]" progress lines.
    private(set) var progress: (done: Int, total: Int)?
    private(set) var lastSeconds: Double?
    private(set) var buildsStarted = 0
    private(set) var pendingRebuild = false
    /// While an agent edits files, failures are shown muted (it is mid-edit).
    var agentEditing = false
    /// A release build of the same sources is running in the background (after a good
    /// debug build); on success it fires `onSuccess` again with the same generation, so
    /// the host swaps to the optimized executable without a visible change.
    private(set) var optimizing = false
    /// The last release executable that went live (nil until one does).
    private(set) var lastReleaseExecutable: URL?
    var onSuccess: ((URL, Int) -> Void)?
    var onFailure: (([CompilerDiagnostic]) -> Void)?

    @ObservationIgnored private let runner: Runner
    @ObservationIgnored private var cancelCurrent: (@Sendable () -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Runs the background release build; nil disables it (tests that inject `runner`,
    /// `SR_PREVIEW_RELEASE=0`).
    @ObservationIgnored var releaseRunner: Runner?
    @ObservationIgnored private var releaseCancel: (@Sendable () -> Void)?
    @ObservationIgnored private var releaseTask: Task<Void, Never>?

    init(project: Project, product: String? = nil, runner: Runner? = nil) {
        self.project = project
        self.product = product ?? project.config.product
        self.scratchPath = Self.canonical(project.root).appendingPathComponent(".build/studio", isDirectory: true)
        self.runner = runner ?? BuildController.swiftPM
        let optOut = ProcessInfo.processInfo.environment["SR_PREVIEW_RELEASE"] == "0"
        self.releaseRunner = (runner == nil && !optOut) ? BuildController.swiftPMRelease : nil
    }

    /// `swift build -c release` into the same scratch path (its own `release/` folder).
    static let swiftPMRelease: Runner = { project, product, scratch in
        let (events, cancel) = ProjectBuilder.stream(project, configuration: "release", product: product, scratchPath: scratch)
        let mapped = AsyncStream<BuildUpdate> { cont in
            let task = Task(priority: .utility) {
                for await e in events { cont.yield(BuildUpdate(e)) }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
        return (mapped, { cancel.cancel() })
    }

    static let swiftPM: Runner = { project, product, scratch in
        let (events, cancel) = ProjectBuilder.stream(project, product: product, scratchPath: scratch)
        let mapped = AsyncStream<BuildUpdate> { cont in
            let task = Task {
                for await e in events { cont.yield(BuildUpdate(e)) }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
        return (mapped, { cancel.cancel() })
    }

    /// The real path (symlinks and /tmp → /private/tmp resolved, like getcwd()). SwiftPM
    /// bakes the scratch path into its module cache, so a build whose scratch path is
    /// spelled differently from the terminal's or the agent's (`--scratch-path
    /// .build/studio` from a cwd) fails with "module … is defined in both …".
    /// `URL.standardized` and `resolvingSymlinksInPath()` both strip /private, hence realpath.
    static func canonical(_ url: URL) -> URL {
        guard let p = realpath(url.path, nil) else { return url }
        defer { free(p) }
        return URL(fileURLWithPath: String(cString: p), isDirectory: true)
    }

    var isBuilding: Bool {
        switch phase {
        case .building, .waitingForLock: return true
        default: return false
        }
    }

    var errors: [CompilerDiagnostic] { diagnostics.filter { $0.severity == .error } }
    var warnings: [CompilerDiagnostic] { diagnostics.filter { $0.severity == .warning } }

    func requestBuild(_ reason: BuildReason) {
        if isBuilding { pendingRebuild = true; return }
        start()
    }

    func cancel() {
        pendingRebuild = false
        cancelCurrent?()
        cancelRelease()
    }

    /// Stops a background release build (a new edit wins: they share the scratch lock).
    func cancelRelease() {
        releaseTask?.cancel()
        releaseTask = nil
        releaseCancel?()
        releaseCancel = nil
        optimizing = false
    }

    private func startRelease(generation gen: Int) {
        cancelRelease()
        guard let releaseRunner else { return }
        optimizing = true
        let (events, cancel) = releaseRunner(project, product, scratchPath)
        releaseCancel = cancel
        releaseTask = Task(priority: .utility) { [weak self] in
            var result: BuildUpdate.Result?
            for await e in events {
                if case .finished(let r) = e { result = r }
            }
            guard let self, !Task.isCancelled else { return }
            self.releaseFinished(result, generation: gen)
        }
    }

    private func releaseFinished(_ r: BuildUpdate.Result?, generation gen: Int) {
        optimizing = false
        releaseCancel = nil
        releaseTask = nil
        // Only the newest debug build's release follow-up may swap; a failed release
        // build is silent (the debug host keeps running).
        guard gen == generation, !isBuilding, let r, r.success, let exe = r.executable else { return }
        lastReleaseExecutable = exe
        onSuccess?(exe, gen)
    }

    private func start() {
        cancelRelease()
        pendingRebuild = false
        buildsStarted += 1
        phase = .building("Starting build…")
        diagnostics = []
        progress = nil
        let (events, cancel) = runner(project, product, scratchPath)
        cancelCurrent = cancel
        task = Task { [weak self] in
            for await e in events {
                guard let self else { return }
                self.handle(e)
            }
            self?.streamEnded()
        }
    }

    /// Exposed for tests: feed one event as if it came from the build.
    func handle(_ e: BuildUpdate) {
        switch e {
        case .progress(let line):
            phase = .building(line)
            if let p = Self.parseProgress(line) { progress = p }
        case .waitingForLock:
            phase = .waitingForLock
        case .diagnostic(let d):
            if !diagnostics.contains(d) { diagnostics.append(d) }
        case .finished(let r):
            log = r.log
            lastSeconds = r.seconds
            diagnostics = r.diagnostics
            cancelCurrent = nil
            if r.success, let exe = r.executable {
                generation += 1
                lastGoodExecutable = exe
                phase = .succeeded(seconds: r.seconds, at: Date())
                onSuccess?(exe, generation)
                if !pendingRebuild { startRelease(generation: generation) }
            } else {
                phase = .failed(r.errors.isEmpty ? Self.fallbackErrors(r.log) : r.errors, log: r.log)
                onFailure?(r.errors)
            }
        }
    }

    private func streamEnded() {
        if isBuilding {     // stream closed without `.finished` (runner bug or cancel)
            phase = .failed([], log: log.isEmpty ? "build ended without a result" : log)
        }
        if pendingRebuild { start() }
    }

    /// "[12/40] Compiling …" → (12, 40).
    static func parseProgress(_ line: String) -> (done: Int, total: Int)? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let inner = line[line.index(after: line.startIndex)..<close].split(separator: "/")
        guard inner.count == 2, let a = Int(inner[0]), let b = Int(inner[1]), b > 0 else { return nil }
        return (a, b)
    }

    /// A failed build with no parseable diagnostic (linker, manifest) still needs a row.
    private static func fallbackErrors(_ log: String) -> [CompilerDiagnostic] {
        let line = log.split(separator: "\n").last(where: { $0.localizedCaseInsensitiveContains("error") })
            .map(String.init) ?? "Build failed"
        return [CompilerDiagnostic(file: "", line: 0, column: 0, severity: .error, message: line)]
    }
}

/// A runner that "builds" instantly: used by `--fake-host` so the watch → build → swap
/// loop runs end to end without compiling (and by tests).
enum SimulatedBuild {
    static func runner(seconds: Double = 0.4, fail: @escaping @Sendable () -> Bool = { false }) -> BuildController.Runner {
        { project, product, scratch in
            let (stream, cont) = AsyncStream.makeStream(of: BuildUpdate.self)
            let task = Task {
                cont.yield(.progress("[1/3] Planning build"))
                try? await Task.sleep(for: .seconds(seconds / 2))
                cont.yield(.progress("[2/3] Compiling \(product) (simulated)"))
                try? await Task.sleep(for: .seconds(seconds / 2))
                let failed = fail()
                let file = project.root.appendingPathComponent("Sources/SwiftRender/Scenes/LaunchFilm.swift").path
                let diags = failed ? [
                    CompilerDiagnostic(file: file, line: 212, column: 14, severity: .error,
                                       message: "cannot convert value of type 'String' to specified type 'Double'"),
                    CompilerDiagnostic(file: file, line: 230, column: 9, severity: .error,
                                       message: "missing return in closure expected to return 'some View'"),
                    CompilerDiagnostic(file: file, line: 88, column: 13, severity: .warning,
                                       message: "initialization of immutable value 'x' was never used"),
                ] : []
                diags.forEach { cont.yield(.diagnostic($0)) }
                cont.yield(.finished(BuildUpdate.Result(success: !failed, seconds: seconds, diagnostics: diags,
                                                 log: failed ? "error: simulated failure" : "Build complete!",
                                                 executable: failed ? nil : scratch.appendingPathComponent("debug/\(product)"))))
                cont.finish()
            }
            return (stream, { task.cancel(); cont.finish() })
        }
    }
}
