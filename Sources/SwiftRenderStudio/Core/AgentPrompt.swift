import Foundation
import SwiftRenderKit

// MARK: - Agent prompt
//
// What Studio tells the director (studio-ux §4.8): the project, scene, source and
// canvas; each comment as `id @ timecode (frame)`, its region in normalized and scene
// points, the clip source `file:line`, the note, the before-frame path and the tail of
// its thread; the loop for the chosen mode; scope; build errors for "fix the build";
// the reviewer's extra instructions. House rules go in the appended system prompt so
// they hold even when the project has no director agent file.

enum AgentPrompt {
    /// Appended system prompt.
    static let houseRules = """
    swift-render house rules:
    - Scenes are pure functions of time. Never add @State, Timer, Date(), unseeded randomness, onAppear or \
    withAnimation to a scene; everything derives from t, duration (and props/audio for those kinds).
    - Audio: no whoosh, riser or swish sounds, even when a note asks for one. Use tick, rim, thump, blip or \
    swell hits, or harmony (pads, arpeggios, bells).
    - \(HouseRules.launchFilm)
    - Stay on the notes you were given: don't refactor, rename or reformat anything else, and never touch \
    another comment's thread.
    - Never edit .swift-render/reviews/*.json by hand; use the swift-render MCP tools (Studio writes those files too).
    - When a note could be read two ways that lead to opposite changes, reply with one specific question and \
    leave the comment open.
    - swift-render Studio is watching: it rebuilds and shows every save live, so keep edits small and compiling.
    """

    static func make(_ r: AgentRequest, info: SceneInfo?, comments: [ReviewComment]) -> (prompt: String, system: String) {
        let root = r.project.root.path
        func rel(_ p: String) -> String { p.hasPrefix(root + "/") ? String(p.dropFirst(root.count + 1)) : p }
        let picked = r.commentIDs.compactMap { id in comments.first { $0.id == id } }
        var out: [String] = []

        // Context
        out.append("Project: \(r.project.root.lastPathComponent) (\(root)), CLI product `\(r.project.config.product)`.")
        if !r.scene.isEmpty {
            var line = "Scene: \(r.scene)"
            if let i = info, i.name == r.scene {
                line += String(format: " — %@, %.2f s, canvas %d×%d @ %d fps", i.kind.rawValue, i.duration, i.width, i.height, i.fps)
                if !i.clips.isEmpty { line += ", \(i.clips.count) clips" }
            }
            out.append(line + ".")
            if let src = info?.sourcePath, info?.name == r.scene { out.append("Source: \(rel(src))") }
        }

        // Comments
        if !picked.isEmpty {
            out.append("")
            out.append("Review comments (ids work with the swift-render MCP tools, e.g. get_comment):")
            for (n, c) in picked.enumerated() {
                out.append("\(n + 1). " + header(c, info: info, rel: rel))
                out.append("   “\(c.body.replacingOccurrences(of: "\n", with: " "))” — \(c.author.name)")
                if let b = c.beforeAttachment { out.append("   Before frame: \(b.path)") }
                if let last = c.replies.last {
                    let more = c.replies.count > 1 ? " (\(c.replies.count) replies; latest)" : ""
                    out.append("   Thread\(more): \(last.author.name): “\(ClaudeStreamDecoder.firstLine(last.body, limit: 200))”")
                }
                if c.status == .resolved || c.status == .wontFix {
                    out.append("   (Reopened from \(c.status.rawValue) — the reviewer wasn't satisfied; read the thread.)")
                }
            }
        }

        // Build errors
        let errors = r.buildDiagnostics.filter { $0.severity == .error }
        if !errors.isEmpty {
            out.append("")
            out.append("The project doesn't compile (\(errors.count) error\(errors.count == 1 ? "" : "s")):")
            for d in errors.prefix(20) {
                out.append(d.file.isEmpty ? "- \(d.message)" : "- \(rel(d.file)):\(d.line):\(d.column): error: \(d.message)")
            }
            if errors.count > 20 { out.append("- … \(errors.count - 20) more") }
        }

        // Task
        out.append("")
        out.append(task(r, hasComments: !picked.isEmpty, hasErrors: !errors.isEmpty))

        // Scope
        if r.mode.edits {
            if r.scope == .sceneFile, let src = info?.sourcePath, info?.name == r.scene, errors.isEmpty {
                out.append("Scope: edit only \(rel(src)). If a note needs another file, reply with what you would change instead.")
            } else {
                out.append("Scope: you may edit files under Sources/. Don't touch Package.swift, tests or other scenes unless the build requires it.")
            }
        }

        let extra = r.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty {
            out.append("")
            out.append("From the reviewer: \(extra)")
        }

        out.append("")
        out.append(picked.isEmpty
                   ? "Finish with one line saying what you changed and where (file:line)."
                   : "Finish with one line per comment: `<id> — resolved: <summary>` / `replied` / `question asked` / `skipped: <why>`.")
        return (out.joined(separator: "\n"), houseRules)
    }

    /// `c1a2b3c4 @ 00:12.40 (f744) · region x 0.10 … = 192,216 576×270 pt · clip Title (TimelineDemo.swift:41)`
    static func header(_ c: ReviewComment, info: SceneInfo?, rel: (String) -> String) -> String {
        let fps = c.canvas?.fps ?? info?.fps ?? 60
        var s = "\(c.id) @ \(c.timecode) (f\(frameIndex(c.t, fps: fps))"
        if let end = c.end { s += "–f\(frameIndex(end, fps: fps))" }
        s += ") · \(c.status.rawValue)"
        if let r = c.region {
            let w = c.canvas?.width ?? info?.width ?? 1920, h = c.canvas?.height ?? info?.height ?? 1080
            let p = r.pixelRect(width: w, height: h)
            s += String(format: " · region %@ = %.0f,%.0f %.0f×%.0f pt of %d×%d", r.label, p.minX, p.minY, p.width, p.height, w, h)
        }
        let clip = info?.clips(at: c.t).last
        if let src = c.source ?? clip?.source {
            let name = clip?.source == src ? clip.map { "\($0.displayName) " } ?? "" : ""
            s += " · clip \(name)(\(rel(src.file)):\(src.line))"
        }
        return s
    }

    private static func task(_ r: AgentRequest, hasComments: Bool, hasErrors: Bool) -> String {
        switch r.mode {
        case .reply:
            return """
            Reply only. Do not edit any files and do not build. For each comment above, read it (get_comment) \
            and answer in its thread with reply_comment as the reviewer asks. Leave every status unchanged.
            """
        case .plan:
            return """
            Propose only. Do not edit any files. For each comment: get_comment (look at the frame and the box), \
            read the code behind it, then reply_comment with a concrete plan: what you would change, where \
            (file:line) and by how much (before → after). Leave the comments open.
            """
        case .fix:
            var steps: [String] = []
            if hasErrors {
                steps.append("""
                First make the project build: fix the errors above with the smallest correct change (usually the \
                last edit that broke it), then build until it is clean.
                """)
            }
            if hasComments {
                steps.append("""
                Then work the comments one at a time. Studio has already claimed them for you (inProgress, \
                assignee Claude). For each: get_comment (frame, box, clip source) → find the code → make the \
                smallest edit that answers the note → build (the `build` tool, or `swift build --scratch-path \
                .build/studio`, Studio's build directory) → render_frames at the note's time and actually look → \
                resolve_comment with what changed, where (file:line) and by how much. If you can't land a fix, \
                revert your edit and reply_comment with what blocked you and reopen: true.
                """)
                steps.append("Before you finish, run check_scene on every scene you edited.")
            }
            return steps.joined(separator: "\n").replacingOccurrences(of: "Then work", with: hasErrors ? "Then work" : "Work")
        }
    }
}
