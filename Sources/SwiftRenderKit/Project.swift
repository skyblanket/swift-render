import Foundation

// MARK: - Project
//
// A swift-render project is any directory with a Package.swift whose executable
// product links SwiftRenderTool (the swift-render repo itself, or a user's
// `Launch/` package). Everything the editor, the review loop and the agent
// share lives under `<root>/.swift-render/`:
//
//   .swift-render/reviews/<Scene>.json     review comments   (commit these)
//   .swift-render/knobs/<Scene>.json       knob overrides    (commit these — they change renders)
//   .swift-render/attachments/*.png        before/after frames for comments
//   .swift-render/cache/                   scratch (gitignored)
//
// An optional `swift-render.json` at the root names the CLI product:
//
//   { "product": "swift-render" }

/// Optional per-project settings read from `<root>/swift-render.json`.
public struct ProjectConfig: Codable, Sendable, Equatable {
    /// Executable product that links SwiftRenderTool. Default "swift-render".
    public var product: String
    /// Directory new scenes are scaffolded into, relative to the root.
    public var scenesDir: String?
    /// Default author name for comments written from this machine.
    public var author: String?

    public init(product: String = "swift-render", scenesDir: String? = nil, author: String? = nil) {
        self.product = product
        self.scenesDir = scenesDir
        self.author = author
    }

    enum CodingKeys: String, CodingKey { case product, scenesDir, author }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        product = try c.decodeIfPresent(String.self, forKey: .product) ?? "swift-render"
        scenesDir = try c.decodeIfPresent(String.self, forKey: .scenesDir)
        author = try c.decodeIfPresent(String.self, forKey: .author)
    }
}

public struct Project: Sendable, Equatable {
    public let root: URL
    public let config: ProjectConfig

    public init(root: URL, config: ProjectConfig = ProjectConfig()) {
        self.root = root.standardizedFileURL
        self.config = config
    }

    /// Load `swift-render.json` (if any) for the package at `root`.
    public static func open(_ root: URL) -> Project {
        let cfgURL = root.appendingPathComponent("swift-render.json")
        let cfg = (try? Data(contentsOf: cfgURL)).flatMap { try? JSONDecoder().decode(ProjectConfig.self, from: $0) }
        return Project(root: root, config: cfg ?? ProjectConfig())
    }

    /// Resolve the project for a process: `$SWIFT_RENDER_ROOT`, else the nearest
    /// ancestor of `start` (default: cwd) with a `swift-render.json`, else the
    /// nearest with a `Package.swift`. The marker file wins over Package.swift so
    /// a `MyApp/Launch/` package isn't shadowed by `MyApp/Package.swift`.
    public static func discover(from start: URL? = nil) -> Project? {
        if let env = ProcessInfo.processInfo.environment["SWIFT_RENDER_ROOT"], !env.isEmpty {
            return open(URL(fileURLWithPath: env, isDirectory: true))
        }
        let begin = (start ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
            .standardizedFileURL
        if let marked = nearest(from: begin, containing: "swift-render.json") { return open(marked) }
        if let pkg = nearest(from: begin, containing: "Package.swift") { return open(pkg) }
        return nil
    }

    private static func nearest(from start: URL, containing file: String) -> URL? {
        var dir = start
        while true {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path) { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
    }

    public var dotDir: URL { root.appendingPathComponent(".swift-render", isDirectory: true) }
    public var reviewsDir: URL { dotDir.appendingPathComponent("reviews", isDirectory: true) }
    public var knobsDir: URL { dotDir.appendingPathComponent("knobs", isDirectory: true) }
    public var attachmentsDir: URL { dotDir.appendingPathComponent("attachments", isDirectory: true) }
    public var cacheDir: URL { dotDir.appendingPathComponent("cache", isDirectory: true) }
    public var rendersDir: URL { root.appendingPathComponent("out", isDirectory: true) }

    public func reviewURL(scene: String) -> URL { reviewsDir.appendingPathComponent("\(scene).json") }
    public func knobsURL(scene: String) -> URL { knobsDir.appendingPathComponent("\(scene).json") }

    /// Default comment author: config, then `git config user.name`, then the login name.
    public func defaultAuthorName() -> String {
        if let a = config.author, !a.isEmpty { return a }
        if let r = try? ProcessRunner.run("/usr/bin/env", ["git", "config", "user.name"], cwd: root),
           r.status == 0 {
            let name = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        return NSUserName()
    }

    /// Creates `.swift-render/` and a `.gitignore` for its cache on first use.
    public func ensureDotDir() throws {
        let fm = FileManager.default
        for d in [reviewsDir, knobsDir, attachmentsDir, cacheDir] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        let ignore = dotDir.appendingPathComponent(".gitignore")
        if !fm.fileExists(atPath: ignore.path) {
            try "cache/\n".write(to: ignore, atomically: true, encoding: .utf8)
        }
    }
}
