import Foundation

// MARK: - Process helper

public struct ProcessResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var seconds: Double
}

public enum ProcessRunner {
    /// Run a program to completion, capturing both streams.
    public static func run(_ executable: String, _ args: [String], cwd: URL? = nil,
                           environment: [String: String]? = nil) throws -> ProcessResult {
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

        let start = Date()
        try p.run()
        p.waitUntilExit()
        group.wait()
        return ProcessResult(status: p.terminationStatus,
                             stdout: String(decoding: outBox.data, as: UTF8.self),
                             stderr: String(decoding: errBox.data, as: UTF8.self),
                             seconds: Date().timeIntervalSince(start))
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
    public static func build(_ project: Project, configuration: String = "debug",
                             product: String? = nil) throws -> BuildResult {
        let prod = product ?? project.config.product
        let r = try ProcessRunner.run("/usr/bin/env",
                                      ["swift", "build", "-c", configuration, "--product", prod],
                                      cwd: project.root)
        let log = r.stdout + r.stderr
        var exe: URL? = nil
        if r.status == 0, let bin = try? binPath(project, configuration: configuration) {
            exe = bin.appendingPathComponent(prod)
        }
        return BuildResult(success: r.status == 0, seconds: r.seconds,
                           diagnostics: CompilerDiagnostic.parse(log), log: log, executable: exe)
    }

    /// `swift build --show-bin-path` (cached per root+configuration).
    public static func binPath(_ project: Project, configuration: String = "debug") throws -> URL {
        let key = project.root.path + "|" + configuration
        if let hit = BinPathCache.shared.get(key) { return hit }
        let r = try ProcessRunner.run("/usr/bin/env",
                                      ["swift", "build", "-c", configuration, "--show-bin-path"],
                                      cwd: project.root)
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
    public static func executable(_ project: Project, configuration: String = "debug") throws -> URL {
        try binPath(project, configuration: configuration).appendingPathComponent(project.config.product)
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
