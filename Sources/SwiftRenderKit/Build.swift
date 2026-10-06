import Foundation

// MARK: - Process helper

public struct ProcessResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var seconds: Double
}

/// Why `ProcessRunner.run` gave up on a child before it exited on its own.
public enum ProcessRunnerError: Error, CustomStringConvertible, Equatable {
    case timedOut(seconds: Double)
    case cancelled

    public var description: String {
        switch self {
        case .timedOut(let s): return String(format: "timed out after %.0fs (stopped)", s)
        case .cancelled: return "cancelled"
        }
    }
}

/// Stops running children on request: SIGTERM to the child's process group (so
/// `swift build`'s compilers and a scene's helpers go too), then SIGKILL after a
/// grace period. One token can serve several runs in sequence; cancelling it also
/// stops any run started later.
public final class ProcessCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var running: [Int32] = []
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// Stops the running child's process group: SIGTERM, then SIGKILL two seconds later
    /// (`hard`: SIGKILL now — for a process that is about to exit itself).
    public func cancel(hard: Bool = false) {
        lock.lock(); cancelled = true; let pids = running; lock.unlock()
        for pid in pids {
            if hard { kill(-pid, SIGKILL); kill(pid, SIGKILL) } else { ProcessRunner.terminateGroup(pid) }
        }
    }

    /// false when already cancelled (the caller then stops the child itself).
    fileprivate func attach(_ pid: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        running.append(pid)
        return true
    }

    fileprivate func detach(_ pid: Int32) {
        lock.lock(); running.removeAll { $0 == pid }; lock.unlock()
    }
}

public enum ProcessRunner {
    /// Run a program to completion, capturing both streams.
    ///
    /// `timeout`: stop the child (and its process group) after that many seconds and
    /// throw `ProcessRunnerError.timedOut`. `cancel`: a token another thread can fire to
    /// stop it early (`ProcessRunnerError.cancelled`).
    public static func run(_ executable: String, _ args: [String], cwd: URL? = nil,
                           environment: [String: String]? = nil, timeout: TimeInterval? = nil,
                           cancel: ProcessCancel? = nil) throws -> ProcessResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        if let environment { p.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice

        // Drain both pipes concurrently so a chatty child can't deadlock on a full pipe.
        let group = DispatchGroup()
        let outBox = DataBox(), errBox = DataBox()
        let outHandle = out.fileHandleForReading, errHandle = err.fileHandleForReading
        group.enter()
        DispatchQueue.global().async { outBox.data = outHandle.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errBox.data = errHandle.readDataToEndOfFile(); group.leave() }

        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        let start = Date()
        do { try p.run() } catch {
            // Nothing will ever write: close our write ends so the readers finish.
            try? out.fileHandleForWriting.close(); try? err.fileHandleForWriting.close()
            throw error
        }
        let pid = p.processIdentifier
        let attached = cancel?.attach(pid) ?? true
        defer { cancel?.detach(pid) }
        if !attached { terminateGroup(pid) }

        var timedOut = false
        if let timeout {
            if exited.wait(timeout: .now() + max(0, timeout)) == .timedOut {
                timedOut = true
                terminateGroup(pid)
                exited.wait()
            }
        } else {
            exited.wait()
        }
        // A grandchild that left the group can keep the pipes open: don't wait on it forever.
        let stopped = timedOut || !attached || (cancel?.isCancelled ?? false)
        if group.wait(timeout: .now() + (stopped ? 2 : 3600)) == .timedOut {
            try? outHandle.close(); try? errHandle.close()
        }
        if timedOut { throw ProcessRunnerError.timedOut(seconds: timeout ?? 0) }
        if stopped { throw ProcessRunnerError.cancelled }
        return ProcessResult(status: p.terminationStatus,
                             stdout: String(decoding: outBox.data, as: UTF8.self),
                             stderr: String(decoding: errBox.data, as: UTF8.self),
                             seconds: Date().timeIntervalSince(start))
    }

    /// SIGTERM to `pid`'s process group (Foundation starts each child in its own group)
    /// and to `pid` itself, then SIGKILL two seconds later for anything still alive.
    public static func terminateGroup(_ pid: Int32) {
        guard pid > 0 else { return }
        kill(-pid, SIGTERM)
        kill(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
    }
}

// MARK: - Compiler diagnostics

public struct CompilerDiagnostic: Codable, Sendable, Equatable, Hashable {
    public enum Severity: String, Codable, Sendable { case error, warning, note }
    public var file: String
    public var line: Int
    public var column: Int
    public var severity: Severity
    public var message: String

    public init(file: String, line: Int, column: Int, severity: Severity, message: String) {
        self.file = file; self.line = line; self.column = column; self.severity = severity; self.message = message
    }

    /// Parses `path:line:col: error|warning|note: message` lines from swiftc / swift build output.
    public static func parse(_ output: String) -> [CompilerDiagnostic] {
        var seen = Set<CompilerDiagnostic>()
        var result: [CompilerDiagnostic] = []
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            guard line.hasPrefix("/") else { continue }
            let parts = line.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
            guard parts.count == 5, let ln = Int(parts[1]), let col = Int(parts[2]) else { continue }
            let sevText = parts[3].trimmingCharacters(in: .whitespaces)
            guard let sev = Severity(rawValue: sevText) else { continue }
            let d = CompilerDiagnostic(file: String(parts[0]), line: ln, column: col, severity: sev,
                                       message: parts[4].trimmingCharacters(in: .whitespaces))
            if seen.insert(d).inserted { result.append(d) }
        }
        return result
    }
}

// MARK: - Build

public struct BuildResult: Sendable {
    public var success: Bool
    public var seconds: Double
    public var diagnostics: [CompilerDiagnostic]
    /// Combined raw output (for a log pane).
    public var log: String
    /// Absolute path of the built executable when `success`.
    public var executable: URL?

    public var errors: [CompilerDiagnostic] { diagnostics.filter { $0.severity == .error } }
}

public enum ProjectBuilder {
    /// `swift build --product <product>` in the project root. Blocking; call off the main thread.
    /// `timeout`/`cancel` stop the build (and its compiler processes) — see `ProcessRunner.run`.
    public static func build(_ project: Project, configuration: String = "debug",
                             product: String? = nil, timeout: TimeInterval? = nil,
                             cancel: ProcessCancel? = nil) throws -> BuildResult {
        let prod = product ?? project.config.product
        let r = try ProcessRunner.run("/usr/bin/env",
                                      ["swift", "build", "-c", configuration, "--product", prod],
                                      cwd: project.root, timeout: timeout, cancel: cancel)
        let log = r.stdout + r.stderr
        var exe: URL? = nil
        if r.status == 0, let bin = try? binPath(project, configuration: configuration, cancel: cancel) {
            exe = bin.appendingPathComponent(prod)
        }
        return BuildResult(success: r.status == 0, seconds: r.seconds,
                           diagnostics: CompilerDiagnostic.parse(log), log: log, executable: exe)
    }

    /// `swift build --show-bin-path` (cached per root+configuration).
    public static func binPath(_ project: Project, configuration: String = "debug",
                               cancel: ProcessCancel? = nil) throws -> URL {
        let key = project.root.path + "|" + configuration
        if let hit = BinPathCache.shared.get(key) { return hit }
        let r = try ProcessRunner.run("/usr/bin/env",
                                      ["swift", "build", "-c", configuration, "--show-bin-path"],
                                      cwd: project.root, timeout: 300, cancel: cancel)
        let path = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.status == 0, !path.isEmpty else {
            throw NSError(domain: "ProjectBuilder", code: Int(r.status),
                          userInfo: [NSLocalizedDescriptionKey: "swift build --show-bin-path failed: \(r.stderr)"])
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        BinPathCache.shared.set(key, url)
        return url
    }

    /// Executable path for the project's CLI product (may not exist yet).
    public static func executable(_ project: Project, configuration: String = "debug",
                                  cancel: ProcessCancel? = nil) throws -> URL {
        try binPath(project, configuration: configuration, cancel: cancel).appendingPathComponent(project.config.product)
    }
}

/// Written by exactly one reader thread, read after `group.wait()`.
private final class DataBox: @unchecked Sendable { var data = Data() }

private final class BinPathCache: @unchecked Sendable {
    static let shared = BinPathCache()
    private var map: [String: URL] = [:]
    private let lock = NSLock()
    func get(_ k: String) -> URL? { lock.lock(); defer { lock.unlock() }; return map[k] }
    func set(_ k: String, _ v: URL) { lock.lock(); map[k] = v; lock.unlock() }
}

// MARK: - Streaming build (Studio's build HUD)

public enum BuildEvent: Sendable {
    /// A progress line, e.g. "[12/40] Compiling SwiftRender NeverHeard.swift".
    case progress(String)
    /// Another SwiftPM process holds the scratch-path lock.
    case waitingForLock
    case diagnostic(CompilerDiagnostic)
    case finished(BuildResult)
}

/// Cancels a running streaming build (SIGINT, then SIGTERM).
public final class BuildCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    fileprivate func attach(_ p: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        process = p
        return !cancelled
    }
    public func cancel() {
        lock.lock(); cancelled = true; let p = process; lock.unlock()
        guard let p, p.isRunning else { return }
        p.interrupt()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { p.terminate() } }
    }
}

public extension ProjectBuilder {
    /// `swift build` with live events. `scratchPath` (e.g. `<root>/.build/studio`) keeps the
    /// editor's builds from contending with the user's own `swift build` lock.
    static func stream(_ project: Project, configuration: String = "debug", product: String? = nil,
                       scratchPath: URL? = nil) -> (events: AsyncStream<BuildEvent>, cancel: BuildCancel) {
        let canceller = BuildCancel()
        let prod = product ?? project.config.product
        var args = ["swift", "build", "-c", configuration, "--product", prod]
        if let scratchPath { args += ["--scratch-path", scratchPath.path] }

        let events = AsyncStream<BuildEvent> { continuation in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = args
            p.currentDirectoryURL = project.root
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            p.standardInput = FileHandle.nullDevice

            let log = LogBox()
            var lines = LineBuffer()
            let start = Date()
            out.fileHandleForReading.readabilityHandler = { h in
                let chunk = h.availableData
                guard !chunk.isEmpty else { return }
                log.append(chunk)
                for line in lines.append(chunk) {
                    let text = String(decoding: line, as: UTF8.self)
                    if text.contains("Another instance of SwiftPM") || text.contains("waiting for lock") {
                        continuation.yield(.waitingForLock)
                    } else if let d = CompilerDiagnostic.parse(text).first, log.firstSighting(d) {
                        continuation.yield(.diagnostic(d))
                    } else if text.hasPrefix("[") || text.hasPrefix("Build") || text.hasPrefix("Compiling") {
                        continuation.yield(.progress(text))
                    }
                }
            }
            p.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                let rest = out.fileHandleForReading.readDataToEndOfFile()
                log.append(rest)
                let text = log.text
                var exe: URL? = nil
                if proc.terminationStatus == 0 {
                    if let scratchPath {
                        exe = scratchPath.appendingPathComponent(configuration).appendingPathComponent(prod)
                    } else if let bin = try? ProjectBuilder.binPath(project, configuration: configuration) {
                        exe = bin.appendingPathComponent(prod)
                    }
                }
                continuation.yield(.finished(BuildResult(success: proc.terminationStatus == 0,
                                                         seconds: Date().timeIntervalSince(start),
                                                         diagnostics: CompilerDiagnostic.parse(text),
                                                         log: text, executable: exe)))
                continuation.finish()
            }
            guard canceller.attach(p) else {
                continuation.yield(.finished(BuildResult(success: false, seconds: 0, diagnostics: [],
                                                         log: "cancelled", executable: nil)))
                continuation.finish()
                return
            }
            do { try p.run() } catch {
                continuation.yield(.finished(BuildResult(success: false, seconds: 0, diagnostics: [],
                                                         log: "failed to start swift build: \(error)",
                                                         executable: nil)))
                continuation.finish()
            }
            continuation.onTermination = { reason in
                if case .cancelled = reason { canceller.cancel() }
            }
        }
        return (events, canceller)
    }
}

/// Accumulates build output; dedupes diagnostics (Swift 6 prints each twice).
private final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var seen = Set<CompilerDiagnostic>()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    func firstSighting(_ d: CompilerDiagnostic) -> Bool {
        lock.lock(); defer { lock.unlock() }; return seen.insert(d).inserted
    }
}
