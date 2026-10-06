import Foundation

// MARK: - Tool paths
//
// An app launched from Finder gets launchd's PATH (/usr/bin:/bin:/usr/sbin:/sbin):
// `swift` resolves through the /usr/bin shim, but `claude` (~/.local/bin) and
// swiftly toolchains do not. Resolve the login shell's PATH once, let Settings
// override individual tools, and hand every child the merged environment.

enum ToolPaths {
    /// UserDefaults key for a per-tool override, e.g. "toolPath.claude".
    static func overrideKey(_ name: String) -> String { "toolPath.\(name)" }

    private static let cache = Cache()

    /// Absolute path of `name`: Settings override, then the login shell's PATH.
    static func resolve(_ name: String) async -> URL? {
        await Task.detached(priority: .userInitiated) { resolveBlocking(name) }.value
    }

    static func resolveBlocking(_ name: String) -> URL? {
        if let o = UserDefaults.standard.string(forKey: overrideKey(name)), !o.isEmpty,
           FileManager.default.isExecutableFile(atPath: o) {
            return URL(fileURLWithPath: o)
        }
        if let hit = cache.get(name) { return hit }
        for dir in searchPath.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                cache.set(name, candidate)
                return candidate
            }
        }
        return nil
    }

    /// The process environment with PATH replaced by the login shell's PATH.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath
        return env
    }

    /// Login-shell PATH merged ahead of the inherited one (cached after first call).
    static var searchPath: String {
        if let p = cache.path { return p }
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let merged = merge(loginShellPATH() ?? "", inherited)
        cache.path = merged
        return merged
    }

    /// Children (including `ProjectBuilder.stream`, which inherits Studio's env) see the login PATH.
    static func installLoginPATH() {
        setenv("PATH", searchPath, 1)
    }

    /// Ordered union of PATH strings, first occurrence wins.
    static func merge(_ paths: String...) -> String {
        var seen = Set<String>()
        var out: [String] = []
        for p in paths {
            for part in p.split(separator: ":").map(String.init) where !part.isEmpty && seen.insert(part).inserted {
                out.append(part)
            }
        }
        // Common install locations a login shell may not export (e.g. when zsh rc files fail).
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for extra in ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"] where seen.insert(extra).inserted {
            out.append(extra)
        }
        return out.joined(separator: ":")
    }

    private static func loginShellPATH() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-lc", "printf %s \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // A broken rc file must not hang Studio's launch.
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline { usleep(10_000) }
        if p.isRunning { p.terminate(); return nil }
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return s.isEmpty ? nil : s
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [String: URL] = [:]
        private var _path: String?
        func get(_ k: String) -> URL? { lock.lock(); defer { lock.unlock() }; return map[k] }
        func set(_ k: String, _ v: URL) { lock.lock(); map[k] = v; lock.unlock() }
        var path: String? {
            get { lock.lock(); defer { lock.unlock() }; return _path }
            set { lock.lock(); _path = newValue; lock.unlock() }
        }
    }
}
