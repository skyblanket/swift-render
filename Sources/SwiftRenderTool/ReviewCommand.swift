import Foundation
import SwiftRender
import SwiftRenderKit
import SwiftUI

// MARK: - swift-render review
//
// Review comments from the terminal (agents without MCP, scripts, CI). Runs
// inside the project's own CLI, so frames render in-process with the same
// scene code the comment is about. Every write goes through ReviewStore (flock).
//
//   review list   [--scene S] [--status open,inProgress|active|all] [--json]
//   review show   <id> [--json]
//   review add    <Scene> --at t [--end t] [--region x,y,w,h] [--author name] [--agent] <body>
//   review reply  <id> <body> [--agent] [--author name] [--attach-frame]
//   review status <id> open|inProgress|resolved|wontFix [--resolution text] [--agent]
//   review frame  <id> [--out path] [--max-width px]
//   review delete <id>
//   review scenes [--json]

struct ReviewCLIError: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}

let reviewUsage = """
usage: swift-render review <command> …
  list   [--scene S] [--status open,inProgress|active|all] [--json]   (default: active)
  show   <id> [--json]
  add    <Scene> --at <t> [--end <t>] [--region x,y,w,h] [--author name] [--agent]
         [--aspect 16:9|9:16|1:1] [--no-still] [--json] <body…>
  reply  <id> <body…> [--agent] [--author name] [--attach-frame] [--json]
  status <id> open|inProgress|resolved|wontFix [--resolution text] [--agent] [--author name] [--json]
  frame  <id> [--out path.png] [--max-width px]     frame at the comment's time, region boxed
  delete <id>                                       remove a comment and its attachment files
  scenes [--json]                                   registered scenes + active comment counts

Ids accept a unique prefix (≥ 4 chars). Regions are normalized 0…1, origin top-left.
Comments live in .swift-render/reviews/<Scene>.json (see docs/review-loop.md).
"""

@MainActor
func runReview(_ args: [String]) throws {
    guard let project = Project.discover() else {
        throw ReviewCLIError("no project here (no swift-render.json or Package.swift above \(FileManager.default.currentDirectoryPath))")
    }
    print(try reviewCommand(args, project: project), terminator: "")
}

/// Runs one `review` subcommand and returns what it prints.
@MainActor
func reviewCommand(_ argv: [String], project: Project) throws -> String {
    guard let sub = argv.first, !["-h", "--help", "help"].contains(sub) else { return reviewUsage }
    let a = try ReviewArgs(Array(argv.dropFirst()))
    let store = ReviewStore(project: project)
    let cli = ReviewCLI(project: project, store: store, args: a)
    switch sub {
    case "list":   return try cli.list()
    case "show":   return try cli.show()
    case "add":    return try cli.add()
    case "reply":  return try cli.reply()
    case "status": return try cli.status()
    case "frame":  return try cli.frame()
    case "delete", "rm": return try cli.delete()
    case "scenes": return try cli.scenes()
    default: throw ReviewCLIError("unknown review command '\(sub)'\n\n" + reviewUsage)
    }
}

/// Flags anywhere, positionals in order; `--` ends flags so a body may start with "-".
struct ReviewArgs {
    static let valued: Set<String> = ["--scene", "--status", "--at", "--end", "--region", "--author",
                                      "--resolution", "--out", "--aspect", "--max-width", "--duration"]
    static let switches: Set<String> = ["--json", "--agent", "--attach-frame", "--no-still"]

    var values: [String: String] = [:]
    var flags: Set<String> = []
    var positional: [String] = []

    init(_ args: [String]) throws {
        var i = 0, literal = false
        while i < args.count {
            let k = args[i]
            if literal || !k.hasPrefix("--") { positional.append(k); i += 1; continue }
            if k == "--" { literal = true; i += 1; continue }
            if Self.switches.contains(k) { flags.insert(k); i += 1; continue }
            guard Self.valued.contains(k) else { throw ReviewCLIError("unknown option \(k)\n\n" + reviewUsage) }
            guard i + 1 < args.count else { throw ReviewCLIError("\(k) needs a value") }
            values[k] = args[i + 1]
            i += 2
        }
    }

    func double(_ k: String) throws -> Double? {
        guard let v = values[k] else { return nil }
        guard let d = Double(v), d.isFinite else { throw ReviewCLIError("\(k) expects seconds, got '\(v)'") }
        return d
    }

    func has(_ flag: String) -> Bool { flags.contains(flag) }

    func positional(_ i: Int, _ what: String) throws -> String {
        guard i < positional.count else { throw ReviewCLIError("missing \(what)\n\n" + reviewUsage) }
        return positional[i]
    }

    /// Positionals from `i` on, joined: the comment/reply body.
    func body(from i: Int) throws -> String {
        let text = positional.dropFirst(i).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ReviewCLIError("missing comment text\n\n" + reviewUsage) }
        return text
    }
}

@MainActor
struct ReviewCLI {
    let project: Project
    let store: ReviewStore
    let args: ReviewArgs

    private var json: Bool { args.has("--json") }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try ReviewStore.encoder.encode(value), as: UTF8.self) + "\n"
    }

    private func author() -> ReviewAuthor {
        if args.has("--agent") { return .agent(args.values["--author"] ?? "Claude") }
        return ReviewAuthor(name: args.values["--author"] ?? project.defaultAuthorName())
    }

    // MARK: read

    func list() throws -> String {
        let filter = try ReviewStatus.parseFilter(args.values["--status"] ?? "active")
        var entries = store.all(status: filter).map { ReviewEntry(scene: $0.scene, comment: $0.comment) }
        if let scene = args.values["--scene"] { entries = entries.filter { $0.scene == scene } }
        if json { return try encode(entries) }
        if entries.isEmpty { return "no comments" + (filter == nil ? "" : " (\(statusWords(filter)))") + "\n" }
        var out = ""
        for (scene, group) in Dictionary(grouping: entries, by: \.scene).sorted(by: { $0.key < $1.key }) {
            out += "\(scene)\n"
            for e in group { out += "  " + e.comment.summaryLine + "\n" }
        }
        return out
    }

    func show() throws -> String {
        let e = try store.resolve(id: try args.positional(0, "comment id"))
        if json { return try encode(e) }
        return describe(e)
    }

    func scenes() throws -> String {
        let counts = Dictionary(grouping: store.all(status: [.open, .inProgress]), by: \.scene).mapValues(\.count)
        let names = sceneRunners.keys.sorted()
        if json {
            struct Row: Encodable { var summary: SceneSummary; var activeComments: Int; var sourcePath: String? }
            return try encode(names.map { n in
                Row(summary: sceneRunners[n]!.summary(name: n), activeComments: counts[n] ?? 0,
                    sourcePath: sceneRunners[n]!.sourcePath)
            })
        }
        return names.map { n in
            let r = sceneRunners[n]!
            let c = counts[n].map { "  · \($0) active comment\($0 == 1 ? "" : "s")" } ?? ""
            return String(format: "%@  %@ %.2fs", n, r.kind.rawValue, r.defaultDuration) + c
        }.joined(separator: "\n") + "\n"
    }

    // MARK: write

    func add() throws -> String {
        let scene = try args.positional(0, "scene name")
        guard let runner = sceneRunners[scene] else {
            throw ReviewCLIError("unknown scene '\(scene)' — try: swift-render list")
        }
        guard let t = try args.double("--at") else { throw ReviewCLIError("add needs --at <seconds>") }
        let end = try args.double("--end")
        let body = try args.body(from: 1)
        let duration = try args.double("--duration") ?? runner.durationFor(nil)
        guard t >= 0, t <= duration + 1e-6 else {
            throw ReviewCLIError(String(format: "--at %.2f is outside %@ (0–%.2fs)", t, scene, duration))
        }
        if let end, end <= t { throw ReviewCLIError("--end must be after --at") }
        var region: ReviewRegion? = nil
        if let r = args.values["--region"] {
            guard let parsed = ReviewRegion(parsing: r) else {
                throw ReviewCLIError("--region expects x,y,w,h normalized 0…1 (e.g. 0.1,0.2,0.3,0.25), got '\(r)'")
            }
            region = parsed
        }
        let aspect = args.values["--aspect"].flatMap(AspectPreset.init(rawValue:)) ?? .landscape16x9
        let canvas = ReviewCanvas(width: Int(aspect.size.width), height: Int(aspect.size.height), fps: 60)

        KnobStore.shared.load(scene: scene, project: project)
        var comment = ReviewComment(t: t, end: end, region: region, body: body, author: author())
        comment.canvas = canvas
        comment.revision = store.currentRevision()
        var context: [String: String] = [:]
        if args.values["--duration"] != nil { context["duration"] = String(duration) }
        if aspect != .landscape16x9 { context["aspect"] = aspect.rawValue }
        let knobs = KnobStore.shared.values
        if !knobs.isEmpty, let data = try? JSONEncoder().encode(knobs) {
            context["knobs"] = String(decoding: data, as: UTF8.self)
        }
        comment.context = context.isEmpty ? nil : context
        // Innermost clip at t, so the agent can jump straight to the code.
        if let make = try? runner.makeView(duration, .none, nil) {
            let structure = SceneProbe.probe(duration: duration, size: aspect.size, fps: canvas.fps, make: make)
            let info = SceneInfo(name: scene, kind: runner.kind, duration: duration, width: canvas.width,
                                 height: canvas.height, fps: canvas.fps, clips: structure.clips)
            comment.source = info.clips(at: t).last?.source
        }

        var note = ""
        if !args.has("--no-still") {
            let rel = ReviewAttachmentPaths.before(comment.id)
            do {
                try renderStill(scene: scene, t: t, canvas: canvas, duration: duration,
                                to: store.url(forAttachment: rel))
                comment.attachments = [ReviewAttachment(kind: .before, path: rel, t: t)]
            } catch {
                note = "  (before still failed: \(error))\n"
            }
        }
        try store.add(scene: scene, comment)
        if json { return try encode(ReviewEntry(scene: scene, comment: comment)) }
        return "added \(comment.id) on \(scene) at \(comment.timecode)\n" + note
            + (comment.beforeAttachment.map { "  before → \($0.path)\n" } ?? "")
    }

    func reply() throws -> String {
        let e = try store.resolve(id: try args.positional(0, "comment id"))
        var reply = ReviewReply(author: author(), body: try args.body(from: 1))
        if args.has("--attach-frame") {
            let rel = ReviewAttachmentPaths.after(e.comment.id, reply: reply.id)
            try renderStill(scene: e.scene, t: e.comment.t, canvas: e.comment.canvas,
                            duration: pinnedDuration(e.comment), to: store.url(forAttachment: rel))
            reply.attachments = [ReviewAttachment(kind: .after, path: rel, t: e.comment.t)]
        }
        let updated = try store.reply(scene: e.scene, id: e.comment.id, reply)
        if json { return try encode(ReviewEntry(scene: e.scene, comment: updated)) }
        return "replied \(reply.id) on \(e.comment.id)\n"
            + (reply.attachments.first.map { "  after → \($0.path)\n" } ?? "")
    }

    func status() throws -> String {
        let e = try store.resolve(id: try args.positional(0, "comment id"))
        let word = try args.positional(1, "status (open, inProgress, resolved, wontFix)")
        guard let s = ReviewStatus(loose: word) else {
            throw ReviewCLIError("unknown status '\(word)' (open, inProgress, resolved, wontFix)")
        }
        let updated = try store.setStatus(scene: e.scene, id: e.comment.id, s, by: author(),
                                          resolution: args.values["--resolution"])
        if json { return try encode(ReviewEntry(scene: e.scene, comment: updated)) }
        return "\(updated.id) → \(updated.status.rawValue)"
            + (updated.assignee.map { " (assignee \($0.name))" } ?? "") + "\n"
    }

    func delete() throws -> String {
        let e = try store.resolve(id: try args.positional(0, "comment id"))
        try store.remove(scene: e.scene, id: e.comment.id)
        return "deleted \(e.comment.id) from \(e.scene)\n"
    }

    func frame() throws -> String {
        let e = try store.resolve(id: try args.positional(0, "comment id"))
        let out = args.values["--out"].map { URL(fileURLWithPath: $0) }
            ?? project.cacheDir.appendingPathComponent("frames/\(e.comment.id).png")
        try project.ensureDotDir()
        let tmp = project.cacheDir.appendingPathComponent("frames/.raw-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try renderStill(scene: e.scene, t: e.comment.t, canvas: e.comment.canvas, duration: pinnedDuration(e.comment), to: tmp)
        let maxWidth = args.values["--max-width"].flatMap(Int.init)
        let png = try ReviewImage.prepare(tmp, region: e.comment.region, maxWidth: maxWidth)
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: out, options: .atomic)
        return "\(out.path)\n"
    }

    // MARK: helpers

    /// Renders the scene at `t` on the comment's canvas with the project's current knobs.
    /// Scene length comes from the code (`duration` only when explicitly pinned) —
    /// the fix under review may be exactly a length change.
    private func renderStill(scene: String, t: Double, canvas: ReviewCanvas?, duration: Double?, to url: URL) throws {
        guard let runner = sceneRunners[scene] else {
            throw ReviewCLIError("scene '\(scene)' is not registered in this binary — rebuild, or check the name")
        }
        KnobStore.shared.load(scene: scene, project: project)
        let dur = duration ?? runner.durationFor(nil)
        let size = canvas.map { CGSize(width: $0.width, height: $0.height) } ?? AspectPreset.landscape16x9.size
        let fps = canvas?.fps ?? 60
        let audio: AudioSource = runner.soundtrack(dur, nil).map { .score($0) } ?? .none
        let recorder = Recorder(config: .init(fps: fps, size: size))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try runner.frame(recorder, url, min(max(0, t), dur), dur, audio, nil)
    }

    /// A length the commenter pinned with `--duration` (context "duration"); nil = the scene's own.
    private func pinnedDuration(_ c: ReviewComment) -> Double? {
        c.context?["duration"].flatMap(Double.init)
    }

    private func statusWords(_ s: Set<ReviewStatus>?) -> String {
        guard let s else { return "all" }
        return ReviewStatus.allCases.filter(s.contains).map(\.rawValue).joined(separator: ",")
    }

    private func describe(_ e: ReviewEntry) -> String {
        let c = e.comment
        var lines = ["\(c.id) · \(e.scene) · \(c.timecode) · \(c.status.rawValue)"]
        lines.append("by \(c.author.name)\(c.author.kind == .agent ? " (agent)" : "") · \(isoDate(c.createdAt))")
        if let a = c.assignee { lines.append("assignee \(a.name)") }
        if let r = c.region { lines.append("region \(r.label)") }
        if let cv = c.canvas { lines.append("canvas \(cv.width)×\(cv.height) @ \(cv.fps)fps") }
        if let s = c.source { lines.append("source \(s.file):\(s.line)") }
        if let rev = c.revision { lines.append("revision \(rev)") }
        for a in c.attachments ?? [] { lines.append("\(a.kind.rawValue) \(a.path)") }
        lines.append("")
        lines.append(c.body)
        for r in c.replies {
            lines.append("")
            lines.append("— \(r.author.name)\(r.author.kind == .agent ? " (agent)" : "") · \(isoDate(r.createdAt)) · \(r.id)")
            lines.append(r.body)
            for a in r.attachments { lines.append("  \(a.kind.rawValue) \(a.path)") }
        }
        if let res = c.resolution { lines.append(""); lines.append("resolution: \(res)") }
        return lines.joined(separator: "\n") + "\n"
    }

    private func isoDate(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }
}
