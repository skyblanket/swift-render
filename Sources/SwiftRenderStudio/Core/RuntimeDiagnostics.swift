import Foundation
import SwiftRenderKit

// MARK: - Runtime diagnostics
//
// Turns a crashed host's stderr (Swift `Fatal error:` line + the runtime backtracer's
// report, enabled via SWIFT_BACKTRACE) into a crash card: the message and the first
// backtrace frame inside the project, shaped like a `CompilerDiagnostic` so the HUD
// and SourceOpener treat it like a build error.

struct HostCrash: Equatable, Sendable {
    /// "Fatal error: Index out of range", or "Host crashed (signal 11)".
    var message: String
    /// First backtrace frame under the project root.
    var location: CompilerDiagnostic?
    /// Symbol of that frame, e.g. "NeverHeard.panel(_:_:)".
    var symbol: String?
    /// The raw report for "Copy backtrace".
    var report: String
    /// Scene time being rendered when it died: the host's breadcrumb, else the supervisor
    /// fills in the playhead.
    var t: Double?
    var signal: Int32?
}

enum RuntimeDiagnostics {
    /// `<symbol> + <offset> in <image> at <path>:<line>[:<col>]` — the backtracer's frame format.
    private static let frameRegex = try! NSRegularExpression(
        pattern: #"^\s*\d+\s+(?:\[[a-z]+\]\s+)?0x[0-9a-fA-F]+\s+(.+?)\s+\+\s+\d+\s+in\s+\S+\s+at\s+(/[^:]+):(\d+)(?::(\d+))?"#,
        options: [.anchorsMatchLines])
    /// Any `/path/File.swift:line[:col]` (fallback for older/other formats).
    private static let pathRegex = try! NSRegularExpression(pattern: #"(/[^\s:]+\.swift):(\d+)(?::(\d+))?"#)
    /// The host's crash breadcrumb (`HostCrashLog`): `[swift-render serve] fatal SIGTRAP while: frame Hello t=1.25`.
    private static let breadcrumbRegex = try! NSRegularExpression(
        pattern: #"fatal \S+ while: (?:frame|still|check) \S+ t=([-+0-9.eE]+)"#)

    /// Scene time of the render that crashed, from the host's breadcrumb (last one wins).
    static func crashTime(_ stderr: String) -> Double? {
        let ns = stderr as NSString
        guard let m = breadcrumbRegex.matches(in: stderr, range: NSRange(location: 0, length: ns.length)).last else { return nil }
        return Double(ns.substring(with: m.range(at: 1)))
    }

    static func parse(stderr: String, projectRoot: URL, signal: Int32? = nil) -> HostCrash {
        let root = projectRoot.standardizedFileURL.path
        let lines = stderr.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var message = "Host crashed" + (signal.map { " (signal \($0))" } ?? "")
        if let fatal = lines.first(where: { $0.contains("Fatal error:") }) {
            // "Swift/Array.swift:691: Fatal error: Index out of range" → "Fatal error: Index out of range"
            message = String(fatal[fatal.range(of: "Fatal error:")!.lowerBound...]).trimmingCharacters(in: .whitespaces)
        } else if let crashed = lines.first(where: { $0.contains("Program crashed:") }) {
            message = crashed.replacingOccurrences(of: "💣", with: "").trimmingCharacters(in: .whitespaces)
        }

        var location: CompilerDiagnostic?
        var symbol: String?
        let ns = stderr as NSString
        for m in frameRegex.matches(in: stderr, range: NSRange(location: 0, length: ns.length)) {
            let path = ns.substring(with: m.range(at: 2))
            guard path.hasPrefix(root) else { continue }
            let col = m.range(at: 4).location != NSNotFound ? Int(ns.substring(with: m.range(at: 4))) ?? 0 : 0
            symbol = ns.substring(with: m.range(at: 1))
            location = CompilerDiagnostic(file: path, line: Int(ns.substring(with: m.range(at: 3))) ?? 0,
                                          column: col, severity: .error, message: message)
            break
        }
        if location == nil {
            for m in pathRegex.matches(in: stderr, range: NSRange(location: 0, length: ns.length)) {
                let path = ns.substring(with: m.range(at: 1))
                guard path.hasPrefix(root) else { continue }
                let col = m.range(at: 3).location != NSNotFound ? Int(ns.substring(with: m.range(at: 3))) ?? 0 : 0
                location = CompilerDiagnostic(file: path, line: Int(ns.substring(with: m.range(at: 2))) ?? 0,
                                              column: col, severity: .error, message: message)
                break
            }
        }
        return HostCrash(message: message, location: location, symbol: symbol, report: stderr, t: crashTime(stderr),
                         signal: signal)
    }
}
