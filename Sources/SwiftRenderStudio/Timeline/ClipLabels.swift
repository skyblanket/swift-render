import Foundation
import SwiftRenderKit

// MARK: - Clip labels
//
// Precedence: `.named("Hero")`, then a name read from the declaring source line
// (`Clip(2.4) { l in typedSignature(l) }` → "typedSignature"), then
// "Clip · File.swift:42". Source files are read once per build generation, so a
// timeline redraw never touches the disk.

@MainActor
final class ClipLabels {
    static let shared = ClipLabels()

    private var key: (clips: [ClipInfo], generation: Int)?
    private var cached: [String: String] = [:]

    /// Display names for `clips`, recomputed when the clips or the build generation change.
    func labels(for clips: [ClipInfo], generation: Int) -> [String: String] {
        if let key, key.generation == generation, key.clips == clips { return cached }
        var lines: [String: [Substring]] = [:]
        var out: [String: String] = [:]
        for c in clips {
            var auto: String?
            if c.label == nil, let src = c.source {
                if lines[src.file] == nil {
                    let text = (try? String(contentsOfFile: src.file, encoding: .utf8)) ?? ""
                    lines[src.file] = text.split(separator: "\n", omittingEmptySubsequences: false)
                }
                if let all = lines[src.file], src.line >= 1, src.line <= all.count {
                    auto = Self.autoLabel(line: String(all[src.line - 1]))
                }
            }
            out[c.id] = Self.name(c, auto: auto)
        }
        key = (clips, generation)
        cached = out
        return out
    }

    nonisolated static func name(_ c: ClipInfo, auto: String?) -> String {
        if let l = c.label, !l.isEmpty { return l }
        if let auto { return auto }
        if let s = c.source { return "Clip · \((s.file as NSString).lastPathComponent):\(s.line)" }
        return "Clip"
    }

    /// The content builder's call on a `Clip(…)` line: `{ l in name(` or `{ Name(`.
    nonisolated static func autoLabel(line: String) -> String? {
        guard let clip = line.range(of: "Clip(") else { return nil }
        let tail = String(line[clip.upperBound...])
        for pattern in [#"in\s+([A-Za-z_]\w*)\s*\("#, #"\{\s*([A-Za-z_]\w*)\s*\("#] {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)),
                  let r = Range(m.range(at: 1), in: tail) else { continue }
            return String(tail[r])
        }
        return nil
    }
}
