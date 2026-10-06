import Foundation
import SwiftRenderKit

// MARK: - The project's own CLI
//
// The server never links scene code: it shells out to the project's CLI product
// (`swift-render` here, `launch` in a user's Launch/ package), rebuilding it only
// when something under Sources/ (or the manifest) is newer than the last build.

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
    /// frame, info, review scenes
    static var quick: TimeInterval { env("SWIFT_RENDER_MCP_TIMEOUT") ?? 180 }
    /// contact, check (many frames + audio synthesis)
    static var sheet: TimeInterval { env("SWIFT_RENDER_MCP_TIMEOUT") ?? 600 }
    static var render: TimeInterval { env("SWIFT_RENDER_MCP_RENDER_TIMEOUT") ?? 3600 }
    static var build: TimeInterval { env("SWIFT_RENDER_MCP_BUILD_TIMEOUT") ?? 1800 }

    static func forCommand(_ args: [String]) -> TimeInterval {
        switch args.first {
        case "render": return render
        case "contact", "check": return sheet
        default: return quick
        }
    }
}

final class ProjectCLI {
    let project: Project
    /// Newest source mtime seen when the current binary was built.
    private var builtFrom: Date?
    private var executable: URL?
    private(set) var lastBuild: BuildResult?
    /// The running tool call's cancel token (set by ToolBox for the call's duration):
    /// `notifications/cancelled` or server shutdown stops the build/render it started.
    var cancel: ProcessCancel?

    init(project: Project) { self.project = project }

    var product: String { project.config.product }

    /// Rebuilds when sources changed since the last build (or the binary is missing/older).
    @discardableResult
    func ensureBuilt(force: Bool = false) throws -> URL {
        let newest = newestSourceDate()
        if !force, let exe = executable, let stamp = builtFrom, newest <= stamp,
           FileManager.default.fileExists(atPath: exe.path) {
            return exe
        }
        if !force, builtFrom == nil, let exe = try? ProjectBuilder.executable(project, cancel: cancel),
           let built = modificationDate(exe), newest <= built {
            executable = exe; builtFrom = newest
            return exe
        }
        log("building \(product) (sources newer than the last build)…")
        let result = try buildNow()
        lastBuild = result
        log(BuildReport.text(result, product: product).components(separatedBy: "\n").first ?? "")
        guard result.success, let exe = result.executable else { throw BuildFailure(result: result) }
        executable = exe; builtFrom = newest
        return exe
    }

    /// Unconditional build (the `build` tool).
    func build() throws -> BuildResult {
        let newest = newestSourceDate()
        let result = try buildNow()
        lastBuild = result
        if result.success, let exe = result.executable { executable = exe; builtFrom = newest }
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

    /// `<bin>/<product> args…` in the project root; builds first if needed. The child is
    /// stopped after `timeout` (default: by command, see `CLITimeouts`) or on cancel.
    func run(_ args: [String], timeout: TimeInterval? = nil) throws -> ProcessResult {
        let exe = try ensureBuilt()
        let limit = timeout ?? CLITimeouts.forCommand(args)
        do {
            return try ProcessRunner.run(exe.path, args, cwd: project.root, timeout: limit, cancel: cancel)
        } catch let e as ProcessRunnerError {
            switch e {
            case .timedOut:
                var why = "`\(product) \(args.joined(separator: " "))` \(e)"
                if args.first == "frame", let i = args.firstIndex(of: "--at"), i + 1 < args.count {
                    why += " — the scene may not terminate at t=\(args[i + 1]) (a loop in body?)"
                }
                throw ToolError(why + ". Set SWIFT_RENDER_MCP_TIMEOUT (seconds) to allow longer.")
            case .cancelled:
                throw ToolError("`\(product) \(args.first ?? "")` cancelled")
            }
        }
    }

    /// Like `run` but throws with the CLI's stderr when it exits non-zero.
    @discardableResult
    func runChecked(_ args: [String]) throws -> ProcessResult {
        let r = try run(args)
        guard r.status == 0 else {
            let err = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ToolError("`\(product) \(args.joined(separator: " "))` failed (exit \(r.status)):\n"
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
