import Foundation
import SwiftRenderKit

// MARK: - The CLI that renders
//
// The server never links scene code: it shells out to a CLI built on SwiftRenderTool —
// the project's own product (`swift-render` here, `launch` in a user's Launch/ package),
// rebuilt only when something under Sources/ (or the manifest) is newer than the last
// build — or, outside a project, the ready-built `swift-render` next to this binary.

struct BuildFailure: Error, CustomStringConvertible {
    var result: BuildResult
    var description: String { BuildReport.text(result) }
}

enum BuildReport {
    /// Diagnostics first (what an agent acts on), then the log tail if nothing parsed.
    static func text(_ r: BuildResult, product: String? = nil) -> String {
        let name = product.map { " \($0)" } ?? ""
        guard !r.success else {
            let warnings = r.diagnostics.filter { $0.severity == .warning }.count
            return String(format: "BUILD OK%@ in %.1fs", name, r.seconds) + (warnings > 0 ? " · \(warnings) warning(s)" : "")
        }
        var lines = [String(format: "BUILD FAILED%@ in %.1fs · %d error(s)", name, r.seconds, r.errors.count)]
        for d in r.diagnostics where d.severity != .note {
            lines.append("\(d.file):\(d.line):\(d.column): \(d.severity.rawValue): \(d.message)")
        }
        if r.errors.isEmpty {
            lines.append("--- log tail ---")
            lines += r.log.split(separator: "\n").suffix(40).map(String.init)
        }
        return lines.joined(separator: "\n")
    }
}

/// How long one CLI child may run before it is stopped (its whole process group).
/// A scene that never terminates at some `t` must not wedge the server for good.
/// `SWIFT_RENDER_MCP_TIMEOUT` (seconds) overrides the frame/info and sheet limits,
/// `SWIFT_RENDER_MCP_RENDER_TIMEOUT` and `SWIFT_RENDER_MCP_BUILD_TIMEOUT` the others.
enum CLITimeouts {
    private static func env(_ k: String) -> TimeInterval? {
        ProcessInfo.processInfo.environment[k].flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil }
    }
    /// frame, info, props, new, review scenes
    static var quick: TimeInterval { env("SWIFT_RENDER_MCP_TIMEOUT") ?? 180 }
    /// contact, check (many frames + audio synthesis), init (scan + scaffold)
    static var sheet: TimeInterval { env("SWIFT_RENDER_MCP_TIMEOUT") ?? 600 }
    /// render, launch
    static var render: TimeInterval { env("SWIFT_RENDER_MCP_RENDER_TIMEOUT") ?? 3600 }
    static var build: TimeInterval { env("SWIFT_RENDER_MCP_BUILD_TIMEOUT") ?? 1800 }

    static func forCommand(_ args: [String]) -> TimeInterval {
        switch args.first {
        case "render", "launch": return render
        case "contact", "check", "init": return sheet
        default: return quick
        }
    }
}

/// A CLI built on SwiftRenderTool (every subcommand of `swift-render`).
protocol SceneCLI: AnyObject {
    /// Shown in messages: the product name.
    var label: String { get }
    /// Working directory for its children (relative paths resolve here).
    var cwd: URL { get }
    /// The running tool call's cancel token (set by ToolBox for the call's duration):
    /// `notifications/cancelled` or server shutdown stops the build/render it started.
    var cancel: ProcessCancel? { get set }
    /// The binary to run, built first if needed.
    func executable() throws -> URL
}

extension SceneCLI {
    /// `<cli> args…` in `cwd` (or `dir`); builds first if needed. The child is stopped after
    /// `timeout` (default: by command, see `CLITimeouts`) or on cancel.
    func run(_ args: [String], timeout: TimeInterval? = nil, cwd dir: URL? = nil,
             environment: [String: String]? = nil) throws -> ProcessResult {
        let exe = try executable()
        let limit = timeout ?? CLITimeouts.forCommand(args)
        do {
            return try ProcessRunner.run(exe.path, args, cwd: dir ?? cwd, environment: environment,
                                         timeout: limit, cancel: cancel)
        } catch let e as ProcessRunnerError {
            switch e {
            case .timedOut:
                var why = "`\(label) \(args.joined(separator: " "))` \(e)"
                if args.first == "frame", let i = args.firstIndex(of: "--at"), i + 1 < args.count {
                    why += " — the scene may not terminate at t=\(args[i + 1]) (a loop in body?)"
                }
                let knob = ["render", "launch"].contains(args.first ?? "") ? "SWIFT_RENDER_MCP_RENDER_TIMEOUT"
                    : "SWIFT_RENDER_MCP_TIMEOUT"
                throw ToolError(why + ". Set \(knob) (seconds) to allow longer.")
            case .cancelled:
                throw ToolError("`\(label) \(args.first ?? "")` cancelled")
            }
        }
    }

    /// Like `run` but throws with the CLI's stderr when it exits non-zero.
    @discardableResult
    func runChecked(_ args: [String], cwd dir: URL? = nil, environment: [String: String]? = nil) throws -> ProcessResult {
        let r = try run(args, cwd: dir, environment: environment)
        guard r.status == 0 else {
            let err = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ToolError("`\(label) \(args.joined(separator: " "))` failed (exit \(r.status)):\n"
                            + String(err.suffix(2000)))
        }
        return r
    }

    /// `info <scene> --json`, decoded.
    func sceneInfo(_ scene: String) throws -> SceneInfo {
        let r = try runChecked(["info", scene, "--json"])
        do { return try JSONDecoder().decode(SceneInfo.self, from: Data(r.stdout.utf8)) }
        catch { throw ToolError("could not decode `info \(scene) --json`: \(error)") }
    }
}

/// The ready-built `swift-render` (standalone mode; `launch` / `init` / `new` everywhere).
final class StandaloneCLI: SceneCLI {
    let url: URL
    let cwd: URL
    var cancel: ProcessCancel?

    init(url: URL, cwd: URL) { self.url = url; self.cwd = cwd }

    var label: String { "swift-render" }

    func executable() throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw ToolError("the swift-render CLI at \(url.path) is gone — rebuild it or set SWIFT_RENDER_CLI")
        }
        return url
    }
}

/// The project's own CLI product, rebuilt when its sources change.
final class ProjectCLI: SceneCLI {
    let project: Project
    /// Newest source mtime seen when the current binary was built.
    private var builtFrom: Date?
    private var executableURL: URL?
    private(set) var lastBuild: BuildResult?
    var cancel: ProcessCancel?

    init(project: Project) { self.project = project }

    var product: String { project.config.product }
    var label: String { product }
    var cwd: URL { project.root }

    func executable() throws -> URL { try ensureBuilt() }

    /// Rebuilds when sources changed since the last build (or the binary is missing/older).
    @discardableResult
    func ensureBuilt(force: Bool = false) throws -> URL {
        let newest = newestSourceDate()
        if !force, let exe = executableURL, let stamp = builtFrom, newest <= stamp,
           FileManager.default.fileExists(atPath: exe.path) {
            return exe
        }
        if !force, builtFrom == nil, let exe = try? ProjectBuilder.executable(project, cancel: cancel),
           let built = modificationDate(exe), newest <= built {
            executableURL = exe; builtFrom = newest
            return exe
        }
        log("building \(product) (sources newer than the last build)…")
        let result = try buildNow()
        lastBuild = result
        log(BuildReport.text(result, product: product).components(separatedBy: "\n").first ?? "")
        guard result.success, let exe = result.executable else { throw BuildFailure(result: result) }
        executableURL = exe; builtFrom = newest
        return exe
    }

    /// Unconditional build (the `build` tool).
    func build() throws -> BuildResult {
        let newest = newestSourceDate()
        let result = try buildNow()
        lastBuild = result
        if result.success, let exe = result.executable { executableURL = exe; builtFrom = newest }
        return result
    }

    /// `swift build` with the build time limit; a timeout or cancel becomes a ToolError.
    private func buildNow() throws -> BuildResult {
        do {
            return try ProjectBuilder.build(project, timeout: CLITimeouts.build, cancel: cancel)
        } catch let e as ProcessRunnerError {
            switch e {
            case .timedOut(let s):
                throw ToolError(String(format: "`swift build --product %@` %@ — another SwiftPM process may hold the "
                                       + ".build lock, or the build is stuck. Set SWIFT_RENDER_MCP_BUILD_TIMEOUT to allow longer.",
                                       product, ProcessRunnerError.timedOut(seconds: s).description))
            case .cancelled: throw ToolError("build cancelled")
            }
        }
    }

    private func newestSourceDate() -> Date {
        var newest = Date.distantPast
        let fm = FileManager.default
        for name in ["Package.swift", "swift-render.json"] {
            if let d = modificationDate(project.root.appendingPathComponent(name)), d > newest { newest = d }
        }
        for dir in ["Sources", "Plugins"] {
            let url = project.root.appendingPathComponent(dir)
            guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.contentModificationDateKey],
                                             options: [.skipsHiddenFiles]) else { continue }
            for case let f as URL in walker {
                if let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                   d > newest { newest = d }
            }
        }
        return newest
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
