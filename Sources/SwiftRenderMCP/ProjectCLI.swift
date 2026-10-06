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

final class ProjectCLI {
    let project: Project
    /// Newest source mtime seen when the current binary was built.
    private var builtFrom: Date?
    private var executable: URL?
    private(set) var lastBuild: BuildResult?

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
        if !force, builtFrom == nil, let exe = try? ProjectBuilder.executable(project),
           let built = modificationDate(exe), newest <= built {
            executable = exe; builtFrom = newest
            return exe
        }
        log("building \(product) (sources newer than the last build)…")
        let result = try ProjectBuilder.build(project)
        lastBuild = result
        log(BuildReport.text(result, product: product).components(separatedBy: "\n").first ?? "")
        guard result.success, let exe = result.executable else { throw BuildFailure(result: result) }
        executable = exe; builtFrom = newest
        return exe
    }

    /// Unconditional build (the `build` tool).
    func build() throws -> BuildResult {
        let newest = newestSourceDate()
        let result = try ProjectBuilder.build(project)
        lastBuild = result
        if result.success, let exe = result.executable { executable = exe; builtFrom = newest }
        return result
    }

    /// `<bin>/<product> args…` in the project root; builds first if needed.
    func run(_ args: [String]) throws -> ProcessResult {
        let exe = try ensureBuilt()
        return try ProcessRunner.run(exe.path, args, cwd: project.root)
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
