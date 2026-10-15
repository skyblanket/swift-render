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
//   .swift-render/props/<Scene>/*.json     saved props variants (`render --props <file>`)
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

    /// Creates a config; `product` defaults to "swift-render".
    public init(product: String = "swift-render", scenesDir: String? = nil, author: String? = nil) {
        self.product = product
        self.scenesDir = scenesDir
        self.author = author
    }

    enum CodingKeys: String, CodingKey { case product, scenesDir, author }

    /// Decodes leniently: a missing `product` means "swift-render".
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        product = try c.decodeIfPresent(String.self, forKey: .product) ?? "swift-render"
        scenesDir = try c.decodeIfPresent(String.self, forKey: .scenesDir)
        author = try c.decodeIfPresent(String.self, forKey: .author)
    }
}

/// A swift-render package on disk and the paths it shares with Studio and agents.
public struct Project: Sendable, Equatable {
    /// Package root directory (standardized).
    public let root: URL
    /// Settings from `swift-render.json`, or defaults.
    public let config: ProjectConfig

    /// Creates a project at `root` with the given config.
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

    /// Resolve the project for a process: `$SWIFT_RENDER_ROOT` (only when no explicit
    /// `start` is given — a folder the user picked wins over the environment), else the
    /// nearest ancestor of `start` (default: cwd) with a `swift-render.json`, else the
    /// nearest with a `Package.swift`. The marker file wins over Package.swift so a
    /// `MyApp/Launch/` package isn't shadowed by `MyApp/Package.swift`; and from an
    /// app root whose `Launch/` holds the swift-render package (what `init` creates),
    /// that `Launch/` is the project.
    public static func discover(from start: URL? = nil) -> Project? {
        if start == nil, let env = ProcessInfo.processInfo.environment["SWIFT_RENDER_ROOT"], !env.isEmpty {
            return open(URL(fileURLWithPath: env, isDirectory: true))
        }
        let begin = (start ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
            .standardizedFileURL
        if let marked = nearest(from: begin, containing: "swift-render.json") { return open(marked) }
        if let pkg = nearest(from: begin, containing: "Package.swift") {
            let launch = pkg.appendingPathComponent("Launch", isDirectory: true)
            if FileManager.default.fileExists(atPath: launch.appendingPathComponent("swift-render.json").path) {
                return open(launch)
            }
            return open(pkg)
        }
        return nil
    }

    private static func nearest(from start: URL, containing file: String) -> URL? {
        // Walk path strings: URL.deletingLastPathComponent() on "/" yields "/..", forever.
        var path = start.standardizedFileURL.path
        while true {
            if FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(file)) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            if path == "/" || path.isEmpty { return nil }
            path = (path as NSString).deletingLastPathComponent
        }
    }

    /// `<root>/.swift-render/`.
    public var dotDir: URL { root.appendingPathComponent(".swift-render", isDirectory: true) }
    /// `.swift-render/reviews/`, one review JSON per scene.
    public var reviewsDir: URL { dotDir.appendingPathComponent("reviews", isDirectory: true) }
    /// `.swift-render/knobs/`, one knob-override JSON per scene.
    public var knobsDir: URL { dotDir.appendingPathComponent("knobs", isDirectory: true) }
    /// `.swift-render/attachments/`, before/after frames for comments.
    public var attachmentsDir: URL { dotDir.appendingPathComponent("attachments", isDirectory: true) }
    /// `.swift-render/cache/`, gitignored scratch.
    public var cacheDir: URL { dotDir.appendingPathComponent("cache", isDirectory: true) }
    /// `<root>/out/`, where renders are written.
    public var rendersDir: URL { root.appendingPathComponent("out", isDirectory: true) }

    // Per-scene files are always direct children of their directory: a scene name is
    // a Swift type name, and anything else (a "../" from an agent's tool call, a
    // crafted review file) maps to a harmless file name instead of a path.
    /// `.swift-render/reviews/<Scene>.json`.
    public func reviewURL(scene: String) -> URL {
        reviewsDir.appendingPathComponent("\(Self.fileComponent(scene: scene)).json")
    }
    /// `.swift-render/knobs/<Scene>.json`.
    public func knobsURL(scene: String) -> URL {
        knobsDir.appendingPathComponent("\(Self.fileComponent(scene: scene)).json")
    }

    /// Saved props variants for a PropsScene, one JSON file each (Studio's Props tab).
    public var propsDir: URL { dotDir.appendingPathComponent("props", isDirectory: true) }
    /// `.swift-render/props/<Scene>/`, the scene's saved props variants.
    public func propsVariantsDir(scene: String) -> URL {
        propsDir.appendingPathComponent(Self.fileComponent(scene: scene), isDirectory: true)
    }

    /// Scene names are Swift type names (SceneRegistryPlugin registers `public struct X`
    /// as "X"): ASCII letters, digits and `_`, not starting with a digit.
    public static func isValidSceneName(_ name: String) -> Bool {
        let scalars = name.unicodeScalars
        guard let first = scalars.first, scalars.count <= 200, !("0"..."9").contains(first) else { return false }
        return scalars.allSatisfy(isWordScalar)
    }

    /// `scene` itself when it is a valid scene name; otherwise one path component with
    /// every character outside `[A-Za-z0-9_-]` replaced by `_` (never "..", never a
    /// "/"), prefixed with `_invalid_`.
    public static func fileComponent(scene: String) -> String {
        if isValidSceneName(scene) { return scene }
        let safe = String(String.UnicodeScalarView(scene.unicodeScalars.prefix(120).map {
            isWordScalar($0) || $0 == "-" ? $0 : "_"
        }))
        return "_invalid_" + safe
    }

    private static func isWordScalar(_ u: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(u) || ("A"..."Z").contains(u) || ("0"..."9").contains(u) || u == "_"
    }

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

    /// Creates `.swift-render/` and a `.gitignore` for its cache (and ReviewStore's
    /// flock files) on first use.
    public func ensureDotDir() throws {
        let fm = FileManager.default
        for d in [reviewsDir, knobsDir, attachmentsDir, cacheDir] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        let ignore = dotDir.appendingPathComponent(".gitignore")
        if !fm.fileExists(atPath: ignore.path) {
            try "cache/\nreviews/.*.lock\n".write(to: ignore, atomically: true, encoding: .utf8)
        }
    }
}
