import Foundation
import SwiftRenderKit

// MARK: - Where the server is, and which CLI it drives
//
// Three modes, decided at start (and again after `init_project`):
//
//   project     — a swift-render project hosts scenes here (swift-render.json, a Package.swift
//                 that uses SwiftRenderTool, or $SWIFT_RENDER_ROOT). Scene tools run its own CLI
//                 product, rebuilt when sources change; review comments live in it.
//   standalone  — any other directory (an app repo, a library, Claude Desktop's "/"). Scene
//                 tools run the `swift-render` CLI that sits next to this binary ($SWIFT_RENDER_CLI,
//                 then PATH): its built-in scenes (AppleLaunch, the demos), `launch` and `init`.
//                 Nothing is built here; nothing from this directory is executed except, for
//                 launch_film / init_project on the workspace itself, `swift package dump-package`.
//   docs-only   — neither: only `docs` (and the resources) work; every other tool says how to fix it.

struct Workspace {
    /// The project whose CLI hosts scenes (nil in standalone / docs-only mode).
    var project: Project?
    /// The codebase the agent works in: launch_film / init_project default, standalone renders' home.
    var root: URL?
    /// A ready-built `swift-render` CLI (nil when none was found).
    var cli: URL?
    /// Why `cli` is nil, when SWIFT_RENDER_CLI named something unusable.
    var cliProblem: String?
    /// The swift-render checkout these binaries were built from (for `init --local`).
    var checkout: URL?

    enum Mode: String { case project, standalone, docsOnly = "docs-only" }

    var mode: Mode { project != nil ? .project : cli != nil ? .standalone : .docsOnly }

    /// One line for initialize, list_scenes and logs.
    var summary: String {
        switch mode {
        case .project:
            let p = project!
            return "mode: project — \(p.root.path) (CLI product `\(p.config.product)`, rebuilt when sources change)"
        case .standalone:
            return "mode: standalone — no swift-render project here; using the CLI \(cli!.path) "
                + "(built-in scenes such as AppleLaunch; launch_film and init_project work on any Swift codebase)"
                + (root.map { "; workspace \($0.path)" } ?? "; no workspace — pass `path` to launch_film / init_project")
        case .docsOnly:
            return "mode: docs-only — no swift-render project and no swift-render CLI found"
                + (cliProblem.map { " (\($0))" } ?? "")
                + ". Build it next to this server (`swift build -c release --product swift-render-mcp --product swift-render` "
                + "in a swift-render checkout), put `swift-render` on PATH, or set SWIFT_RENDER_CLI."
        }
    }

    // MARK: discovery

    static func discover(environment env: [String: String] = ProcessInfo.processInfo.environment,
                         cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
                         executable: URL? = Bundle.main.executableURL) -> Workspace {
        var w = Workspace()
        let explicit = !(env["SWIFT_RENDER_ROOT"] ?? "").isEmpty
        // A client that starts servers somewhere else (Claude Desktop: `/`) names the codebase.
        var start = cwd
        if let named = env["SWIFT_RENDER_WORKSPACE"], !named.isEmpty {
            var isDir: ObjCBool = false
            let url = URL(fileURLWithPath: (named as NSString).expandingTildeInPath, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { start = url }
        }
        let found = explicit ? Project.discover() : Project.discover(from: start)
        if let p = found, explicit || hostsScenes(p.root) { w.project = p }
        w.root = workspaceRoot(from: start, home: homeDirectory(env))
            ?? w.project.map { appRoot(forProject: $0.root) }
        (w.cli, w.cliProblem) = findCLI(env: env, executable: executable)
        w.checkout = [executable, w.cli].compactMap { $0 }.lazy.compactMap(swiftRenderCheckout(around:)).first
        return w
    }

    /// A package hosts scenes when it says so (swift-render.json) or its manifest links
    /// SwiftRenderTool (this repo, a `Launch/` package, any package with its own CLI).
    static func hostsScenes(_ root: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent("swift-render.json").path) { return true }
        guard let manifest = try? String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8) else {
            return false
        }
        return manifest.contains("SwiftRenderTool")
    }

    /// The nearest folder at or above `cwd` that looks like a codebase (Package.swift,
    /// *.xcodeproj, *.xcworkspace, .git) — never `/` or the home folder itself; for a
    /// `Launch/` package made by `init`, its app. Else `cwd` (when that is not `/` or home).
    static func workspaceRoot(from cwd: URL, home: URL) -> URL? {
        let fm = FileManager.default
        let start = cwd.canonical
        let homePath = home.canonical.path
        func banned(_ path: String) -> Bool { path == "/" || path.isEmpty || path == homePath }
        var path = start.path
        while !banned(path) {
            let names = (try? fm.contentsOfDirectory(atPath: path)) ?? []
            if names.contains(where: { $0 == "Package.swift" || $0 == ".git" || $0.hasSuffix(".xcodeproj")
                                        || $0.hasSuffix(".xcworkspace") }) {
                return appRoot(forProject: URL(fileURLWithPath: path, isDirectory: true))
            }
            path = (path as NSString).deletingLastPathComponent
        }
        return banned(start.path) ? nil : start
    }

    /// `MyApp/Launch` (what `init` makes) → `MyApp`; anything else → itself.
    static func appRoot(forProject root: URL) -> URL {
        let fm = FileManager.default
        guard root.lastPathComponent == "Launch",
              fm.fileExists(atPath: root.appendingPathComponent("swift-render.json").path) else { return root }
        return root.deletingLastPathComponent().standardizedFileURL
    }

    static func homeDirectory(_ env: [String: String]) -> URL {
        URL(fileURLWithPath: env["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory(), isDirectory: true)
    }

    /// `$SWIFT_RENDER_CLI`, else `swift-render` next to this binary (as launched, then with
    /// symlinks resolved), else on PATH.
    static func findCLI(env: [String: String], executable: URL?) -> (URL?, String?) {
        let fm = FileManager.default
        if let explicit = env["SWIFT_RENDER_CLI"], !explicit.isEmpty {
            let url = URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
            return fm.isExecutableFile(atPath: url.path) ? (url, nil) : (nil, "SWIFT_RENDER_CLI=\(explicit) is not executable")
        }
        var dirs: [URL] = []
        if let exe = executable {
            dirs.append(exe.deletingLastPathComponent())
            dirs.append(exe.canonical.deletingLastPathComponent())
        }
        dirs += (env["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
        for dir in dirs {
            let candidate = dir.appendingPathComponent("swift-render")
            if fm.isExecutableFile(atPath: candidate.path) { return (candidate.standardizedFileURL, nil) }
        }
        return (nil, nil)
    }

    /// The swift-render package a binary was built in (`<checkout>/.build/…/swift-render`).
    static func swiftRenderCheckout(around binary: URL) -> URL? {
        var dir = binary.canonical.deletingLastPathComponent()
        for _ in 0..<8 {
            let manifest = dir.appendingPathComponent("Package.swift")
            if let text = try? String(contentsOf: manifest, encoding: .utf8),
               text.range(of: #"name:\s*"SwiftRender""#, options: .regularExpression) != nil,
               FileManager.default.fileExists(atPath: dir.appendingPathComponent("Sources/SwiftRenderTool").path) {
                return dir.standardizedFileURL
            }
            let up = dir.deletingLastPathComponent()
            if up.path == dir.path { break }
            dir = up
        }
        return nil
    }
}

// MARK: - Paths an agent hands us

extension URL {
    /// The real path: `..` folded, then every symlink in the longest existing prefix resolved
    /// by the kernel (`realpath`), the rest appended. Two spellings of one place compare equal
    /// (`/tmp/x` and `/private/tmp/x`), and a symlink can't smuggle a write out of a folder.
    var canonical: URL {
        let std = standardizedFileURL
        var head = std.path
        var tail: [String] = []
        while head.count > 1 {
            if let r = realpath(head, nil) {
                defer { free(r) }
                var out = URL(fileURLWithPath: String(cString: r))
                for c in tail { out.appendPathComponent(c) }
                return out
            }
            tail.insert((head as NSString).lastPathComponent, at: 0)
            head = (head as NSString).deletingLastPathComponent
        }
        return std
    }
}

enum SafePath {
    /// Folders a tool must never scan or write into, whatever an agent asks.
    static let systemPrefixes = ["/System", "/usr", "/bin", "/sbin", "/etc", "/private/etc", "/private/var/db",
                                 "/Library", "/Applications", "/cores", "/dev"]

    /// An existing directory, symlinks resolved; `~` expanded; relative to `base`. Never `/`,
    /// the home folder itself or a system folder.
    static func codebase(_ raw: String, base: URL?, home: URL) throws -> URL {
        let expanded = (raw as NSString).expandingTildeInPath
        guard !expanded.contains("\0") else { throw ToolError("path contains a NUL byte") }
        let url: URL
        if expanded.hasPrefix("/") {
            url = URL(fileURLWithPath: expanded, isDirectory: true)
        } else if let base {
            url = base.appendingPathComponent(expanded, isDirectory: true)
        } else {
            throw ToolError("'\(raw.prefix(200))' is relative and there is no workspace — pass an absolute path")
        }
        let resolved = url.canonical
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue else {
            throw ToolError("path must be an existing directory: \(resolved.path)")
        }
        let p = resolved.path
        let homePath = home.canonical.path
        if p == "/" || p == homePath {
            throw ToolError("refusing to use \(p) itself — pass the codebase folder (e.g. \(homePath)/Code/MyApp)")
        }
        if let bad = systemPrefixes.first(where: { p == $0 || p.hasPrefix($0 + "/") }) {
            throw ToolError("refusing a path under \(bad): \(p)")
        }
        return resolved
    }

    /// Whether `url` is `dir` or inside it (both symlink-resolved, compared by component).
    static func isInside(_ url: URL, _ dir: URL) -> Bool {
        let a = url.canonical.pathComponents
        let b = dir.canonical.pathComponents
        return a.count >= b.count && Array(a.prefix(b.count)) == b
    }

    /// Path text relative to `base` when inside it, else absolute.
    static func display(_ url: URL, from base: URL?) -> String {
        guard let base, isInside(url, base) else { return url.path }
        let a = url.canonical.pathComponents
        let n = base.canonical.pathComponents.count
        let rest = a.dropFirst(n)
        return rest.isEmpty ? "." : rest.joined(separator: "/")
    }
}
