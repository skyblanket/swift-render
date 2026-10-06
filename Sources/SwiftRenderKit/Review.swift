import Foundation

// MARK: - Review comments
//
// Timecoded (optionally region-pinned) notes on a scene, written by people in
// Studio and picked up by agents (Claude Code via `swift-render-mcp`, or the
// `swift-render review` CLI). One pretty-printed JSON file per scene under
// `.swift-render/reviews/` so threads diff and merge cleanly in git.

public enum ReviewStatus: String, Codable, Sendable, CaseIterable {
    case open
    /// An agent (or person) has claimed it and is working on it.
    case inProgress
    case resolved
    case wontFix

    public var isActive: Bool { self == .open || self == .inProgress }
}

public struct ReviewAuthor: Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable { case human, agent }
    public var name: String
    public var kind: Kind
    public init(name: String, kind: Kind = .human) { self.name = name; self.kind = kind }
    public static func agent(_ name: String = "Claude") -> ReviewAuthor { ReviewAuthor(name: name, kind: .agent) }
}

/// Normalized rectangle on the frame, origin top-left, 0…1 in both axes.
public struct ReviewRegion: Codable, Sendable, Equatable, Hashable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }
}

public struct ReviewAttachment: Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable { case before, after, frame, video }
    public var kind: Kind
    /// Path relative to the project root (e.g. `.swift-render/attachments/c1a2b3c4-after.png`).
    public var path: String
    /// Scene time the attachment shows.
    public var t: Double?
    public init(kind: Kind, path: String, t: Double? = nil) { self.kind = kind; self.path = path; self.t = t }
}

public struct ReviewReply: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var author: ReviewAuthor
    public var body: String
    public var createdAt: Date
    public var attachments: [ReviewAttachment]

    public init(id: String = ReviewIDs.make("r"), author: ReviewAuthor, body: String,
                createdAt: Date = Date(), attachments: [ReviewAttachment] = []) {
        self.id = id; self.author = author; self.body = body
        self.createdAt = createdAt; self.attachments = attachments
    }
}

public struct ReviewComment: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// Scene time the note is about (seconds).
    public var t: Double
    /// Optional end of a time range (seconds) — "this whole beat drags".
    public var end: Double?
    public var region: ReviewRegion?
    public var body: String
    public var author: ReviewAuthor
    public var status: ReviewStatus
    public var createdAt: Date
    public var updatedAt: Date
    public var replies: [ReviewReply]
    /// Short note on how it was resolved (agent or human).
    public var resolution: String?
    /// Who is working on it while `status == .inProgress`.
    public var assignee: ReviewAuthor?
    /// Knob/props/duration context at comment time so an agent can reproduce the frame
    /// (keys: "knobs" JSON, "propsSHA", "duration", "aspect", "build").
    public var context: [String: String]?
    /// Frames attached to the comment itself (`.before` is captured at creation).
    public var attachments: [ReviewAttachment]?
    /// What `region` is normalized against.
    public var canvas: ReviewCanvas?
    /// Innermost clip at `t` when the comment was made (`SceneInfo.clips(at:).last?.source`).
    public var source: SourceLocation?
    /// Git revision the comment was made against, e.g. "a63f3d5" or "a63f3d5+dirty".
    public var revision: String?
    /// Human sign-off on an agent's resolution.
    public var acceptedBy: ReviewAuthor?

    public init(id: String = ReviewIDs.make("c"), t: Double, end: Double? = nil, region: ReviewRegion? = nil,
                body: String, author: ReviewAuthor, status: ReviewStatus = .open,
                createdAt: Date = Date(), replies: [ReviewReply] = [], resolution: String? = nil,
                assignee: ReviewAuthor? = nil, context: [String: String]? = nil) {
        self.id = id; self.t = t; self.end = end; self.region = region; self.body = body
        self.author = author; self.status = status; self.createdAt = createdAt; self.updatedAt = createdAt
        self.replies = replies; self.resolution = resolution; self.assignee = assignee; self.context = context
    }

    /// "00:12.40" or "00:12.40–00:13.00".
    public var timecode: String {
        let a = ReviewComment.format(t)
        if let end { return "\(a)–\(ReviewComment.format(end))" }
        return a
    }

    /// "MM:SS.ss". Safe for any input: non-finite times print as "--:--.--", and huge
    /// ones are clamped (Int(t) would trap past Int.max).
    public static func format(_ t: Double) -> String {
        guard t.isFinite else { return "--:--.--" }
        let s = min(max(t, -359_999.99), 359_999.99)
        return String(format: "%02d:%05.2f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }
}

public struct ReviewCanvas: Codable, Sendable, Equatable, Hashable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public init(width: Int, height: Int, fps: Int) { self.width = width; self.height = height; self.fps = fps }
}

public enum ReviewAttachmentPaths {
    /// Project-relative directory every attachment file lives in.
    public static let directory = ".swift-render/attachments/"

    /// `.swift-render/attachments/<commentID>-before.png` (project-relative). Ids come
    /// from shared review files, so they are made file-safe: the result is always a
    /// direct child of the attachments directory.
    public static func before(_ commentID: String) -> String {
        directory + "\(ReviewIDs.fileSafe(commentID))-before.png"
    }
    /// `.swift-render/attachments/<commentID>-after-<replyID>.png` (project-relative).
    public static func after(_ commentID: String, reply replyID: String) -> String {
        directory + "\(ReviewIDs.fileSafe(commentID))-after-\(ReviewIDs.fileSafe(replyID)).png"
    }
}

public struct ReviewFile: Codable, Sendable, Equatable {
    public var version: Int
    public var scene: String
    public var comments: [ReviewComment]

    public init(scene: String, comments: [ReviewComment] = []) {
        self.version = 1; self.scene = scene; self.comments = comments
    }

    public mutating func sort() {
        comments.sort { ($0.t, $0.createdAt) < ($1.t, $1.createdAt) }
    }
}

public enum ReviewIDs {
    /// Short random id: "c" + 8 hex chars. Collisions within one scene are vanishingly rare.
    public static func make(_ prefix: String) -> String {
        prefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
    }

    /// Ids that are safe to use in a file name: 1–64 of `[A-Za-z0-9_-]`. Everything
    /// `make` produces qualifies; a hand-edited or hostile review file may not.
    public static func isValid(_ id: String) -> Bool {
        let s = id.unicodeScalars
        return (1...64).contains(s.count) && s.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-"
        }
    }

    /// `id` when valid; otherwise `x` + a stable 16-hex-digit hash of it, so a crafted
    /// id like "../../x" can never become a path.
    public static func fileSafe(_ id: String) -> String {
        if isValid(id) { return id }
        var h: UInt64 = 0xcbf2_9ce4_8422_2325          // FNV-1a
        for b in id.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        return "x" + String(format: "%016llx", h)
    }
}

public enum ReviewError: Error, CustomStringConvertible {
    case notFound(scene: String, id: String)
    case io(String)
    public var description: String {
        switch self {
        case .notFound(let s, let id): return "no comment \(id) on scene \(s)"
        case .io(let why): return why
        }
    }
}

/// Reads and writes `.swift-render/reviews/<Scene>.json`. Writers (Studio, MCP,
/// CLI) can run concurrently, so every read-modify-write holds an `flock`.
public struct ReviewStore: Sendable {
    public let project: Project

    public init(project: Project) { self.project = project }

    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Scenes that have a review file.
    public func scenes() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: project.reviewsDir.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    public func load(scene: String) throws -> ReviewFile {
        let url = project.reviewURL(scene: scene)
        guard FileManager.default.fileExists(atPath: url.path) else { return ReviewFile(scene: scene) }
        do { return try Self.decoder.decode(ReviewFile.self, from: Data(contentsOf: url)) }
        catch { throw ReviewError.io("cannot read \(url.path): \(error)") }
    }

    /// All comments across scenes, optionally filtered.
    public func all(status: Set<ReviewStatus>? = nil) -> [(scene: String, comment: ReviewComment)] {
        scenes().flatMap { scene -> [(scene: String, comment: ReviewComment)] in
            let file = (try? load(scene: scene)) ?? ReviewFile(scene: scene)
            return file.comments
                .filter { status == nil || status!.contains($0.status) }
                .map { (scene: scene, comment: $0) }
        }
    }

    /// Locked read-modify-write. The closure's mutations are saved atomically.
    @discardableResult
    public func mutate<R>(scene: String, _ body: (inout ReviewFile) throws -> R) throws -> R {
        try project.ensureDotDir()
        let lockURL = project.reviewsDir.appendingPathComponent(".\(Project.fileComponent(scene: scene)).lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw ReviewError.io("cannot open lock \(lockURL.path)") }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }

        var file = try load(scene: scene)
        let result = try body(&file)
        file.sort()
        let data = try Self.encoder.encode(file)
        try data.write(to: project.reviewURL(scene: scene), options: .atomic)
        return result
    }

    // MARK: Convenience operations (shared by Studio, CLI and MCP)

    @discardableResult
    public func add(scene: String, _ comment: ReviewComment) throws -> ReviewComment {
        try mutate(scene: scene) { $0.comments.append(comment) }
        return comment
    }

    @discardableResult
    public func reply(scene: String, id: String, _ reply: ReviewReply) throws -> ReviewComment {
        try mutate(scene: scene) { file in
            guard let i = file.comments.firstIndex(where: { $0.id == id }) else {
                throw ReviewError.notFound(scene: scene, id: id)
            }
            file.comments[i].replies.append(reply)
            file.comments[i].updatedAt = Date()
            return file.comments[i]
        }
    }

    @discardableResult
    public func setStatus(scene: String, id: String, _ status: ReviewStatus,
                          by author: ReviewAuthor? = nil, resolution: String? = nil) throws -> ReviewComment {
        try mutate(scene: scene) { file in
            guard let i = file.comments.firstIndex(where: { $0.id == id }) else {
                throw ReviewError.notFound(scene: scene, id: id)
            }
            try Self.apply(status, by: author, resolution: resolution, to: &file.comments[i])
            return file.comments[i]
        }
    }

    /// Like `setStatus`, but `check` runs on the comment as it is *under the lock*, right
    /// before the change — so a decision made from an earlier read (an agent's claim or
    /// resolve after a long render) can't overwrite what a person did meanwhile.
    /// `check` throws to refuse.
    @discardableResult
    public func transition(scene: String, id: String, to status: ReviewStatus, by author: ReviewAuthor? = nil,
                           resolution: String? = nil,
                           check: (ReviewComment) throws -> Void) throws -> ReviewComment {
        try mutate(scene: scene) { file in
            guard let i = file.comments.firstIndex(where: { $0.id == id }) else {
                throw ReviewError.notFound(scene: scene, id: id)
            }
            try check(file.comments[i])
            try Self.apply(status, by: author, resolution: resolution, to: &file.comments[i])
            return file.comments[i]
        }
    }

    /// A status change. A human's sign-off (`acceptedBy`) is about one specific
    /// resolution, so it is cleared whenever the status changes (reopen, claim, wontFix)
    /// or a different resolution replaces the accepted one.
    private static func apply(_ status: ReviewStatus, by author: ReviewAuthor?, resolution: String?,
                              to c: inout ReviewComment) throws {
        let previous = c.status
        if status != previous || (resolution != nil && resolution != c.resolution) { c.acceptedBy = nil }
        c.status = status
        c.assignee = status == .inProgress ? author : nil
        if let resolution { c.resolution = resolution }
        c.updatedAt = Date()
    }

    @discardableResult
    public func update(scene: String, id: String, _ edit: (inout ReviewComment) -> Void) throws -> ReviewComment {
        try mutate(scene: scene) { file in
            guard let i = file.comments.firstIndex(where: { $0.id == id }) else {
                throw ReviewError.notFound(scene: scene, id: id)
            }
            edit(&file.comments[i])
            file.comments[i].updatedAt = Date()
            return file.comments[i]
        }
    }

    public func delete(scene: String, id: String) throws {
        try mutate(scene: scene) { file in
            guard let i = file.comments.firstIndex(where: { $0.id == id }) else {
                throw ReviewError.notFound(scene: scene, id: id)
            }
            file.comments.remove(at: i)
        }
    }

    /// Find a comment by id in any scene.
    public func find(id: String) -> (scene: String, comment: ReviewComment)? {
        for scene in scenes() {
            if let c = (try? load(scene: scene))?.comments.first(where: { $0.id == id }) {
                return (scene, c)
            }
        }
        return nil
    }
}

// MARK: - Parsing and lookup helpers (shared by the review CLI, MCP server and Studio)

public extension ReviewStatus {
    /// Lenient parse for CLI/agent input: "inProgress", "in-progress", "in_progress",
    /// "wontfix", "won't fix", … (case-insensitive).
    init?(loose text: String) {
        switch text.lowercased().filter(\.isLetter) {
        case "open", "reopen": self = .open
        case "inprogress", "progress", "claimed": self = .inProgress
        case "resolved", "done", "fixed": self = .resolved
        case "wontfix", "wontdo": self = .wontFix
        default: return nil
        }
    }

    /// Comma-separated filter: "open,inProgress" → that set; "active" → open + inProgress;
    /// "all" → nil (no filter). Throws on an unknown word.
    static func parseFilter(_ text: String) throws -> Set<ReviewStatus>? {
        var out = Set<ReviewStatus>()
        for raw in text.split(separator: ",") {
            let word = raw.trimmingCharacters(in: .whitespaces)
            switch word.lowercased() {
            case "all": return nil
            case "active": out.formUnion([.open, .inProgress])
            default:
                guard let s = ReviewStatus(loose: word) else {
                    throw ReviewError.io("unknown status '\(word)' (open, inProgress, resolved, wontFix, active, all)")
                }
                out.insert(s)
            }
        }
        return out.isEmpty ? nil : out
    }
}

public extension ReviewRegion {
    /// Parses "x,y,w,h" (normalized 0…1, origin top-left), clamped to the frame.
    /// nil when malformed or empty.
    init?(parsing text: String) {
        let v = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard v.count == 4, v[2] > 0, v[3] > 0 else { return nil }
        let c = ReviewRegion(x: v[0], y: v[1], w: v[2], h: v[3]).clamped
        guard c.w > 0, c.h > 0 else { return nil }
        self = c
    }

    /// The part of the region inside the unit square.
    var clamped: ReviewRegion {
        // Leave in-bounds values untouched (x + w - x isn't always w in floating point).
        if x >= 0, y >= 0, w >= 0, h >= 0, x + w <= 1, y + h <= 1 { return self }
        let x0 = min(max(x, 0), 1), y0 = min(max(y, 0), 1)
        let x1 = min(max(x + w, 0), 1), y1 = min(max(y + h, 0), 1)
        return ReviewRegion(x: x0, y: y0, w: max(0, x1 - x0), h: max(0, y1 - y0))
    }

    /// Pixel rectangle (origin top-left) on a `width`×`height` image.
    func pixelRect(width: Int, height: Int) -> CGRect {
        let c = clamped
        return CGRect(x: c.x * Double(width), y: c.y * Double(height),
                      width: c.w * Double(width), height: c.h * Double(height))
    }

    /// "x 0.10 y 0.20 w 0.30 h 0.40"
    var label: String { String(format: "x %.2f y %.2f w %.2f h %.2f", x, y, w, h) }
}

public extension ReviewComment {
    /// The frame captured when the comment was made (or first claimed).
    var beforeAttachment: ReviewAttachment? { attachments?.first { $0.kind == .before } }

    /// The newest `.after` frame attached on a reply.
    var latestAfter: ReviewAttachment? {
        for reply in replies.reversed() {
            if let a = reply.attachments.last(where: { $0.kind == .after }) { return a }
        }
        return nil
    }

    /// One line for terminal lists: `c1a2b3c4  00:12.40  open  ▢  body  (2 replies)`.
    var summaryLine: String {
        let flat = body.replacingOccurrences(of: "\n", with: " ")
        let short = flat.count > 72 ? String(flat.prefix(71)) + "…" : flat
        var s = "\(id)  \(timecode)  \(status.rawValue)"
        if region != nil { s += "  ▢" }
        s += "  \(short)"
        if !replies.isEmpty { s += "  (\(replies.count) repl\(replies.count == 1 ? "y" : "ies"))" }
        return s
    }
}

/// A comment with its scene — the shape `review … --json` and the MCP server emit.
public struct ReviewEntry: Codable, Sendable, Equatable {
    public var scene: String
    public var comment: ReviewComment
    public init(scene: String, comment: ReviewComment) { self.scene = scene; self.comment = comment }
}

public extension ReviewStore {
    /// Find by exact id, else by a unique prefix (≥ 4 characters) across all scenes.
    func resolve(id: String) throws -> ReviewEntry {
        if let hit = find(id: id) { return ReviewEntry(scene: hit.scene, comment: hit.comment) }
        func notFound() -> Error {
            let broken = unreadableScenes()
            guard !broken.isEmpty else { return ReviewError.notFound(scene: "*", id: id) }
            return ReviewError.io("no comment \(id) in the readable review files; unreadable: "
                                  + broken.map { "\($0.scene) (\($0.error))" }.joined(separator: "; "))
        }
        guard id.count >= 4 else { throw notFound() }
        let matches = all().filter { $0.comment.id.hasPrefix(id) }
        if matches.count == 1 { return ReviewEntry(scene: matches[0].scene, comment: matches[0].comment) }
        if matches.isEmpty { throw notFound() }
        throw ReviewError.io("ambiguous id \(id): " + matches.map(\.comment.id).joined(separator: ", "))
    }

    /// Absolute URL for a project-relative attachment path (for reading/displaying).
    /// Anything that writes or deletes uses `containedAttachmentURL` instead.
    func url(forAttachment path: String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : project.root.appendingPathComponent(path).standardizedFileURL
    }

    /// The file an attachment path names, only when it is a plain file name directly
    /// inside `.swift-render/attachments/` (no "..", no subdirectories, no absolute
    /// paths, no symlinked parent leading elsewhere); nil otherwise. Review files are
    /// shared through git, so their paths are untrusted.
    func containedAttachmentURL(_ path: String) -> URL? {
        let prefix = ReviewAttachmentPaths.directory
        guard path.hasPrefix(prefix) else { return nil }
        let name = String(path.dropFirst(prefix.count))
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { return nil }
        let dir = project.attachmentsDir
        let target = dir.appendingPathComponent(name)
        let parent = target.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        guard parent == dir.resolvingSymlinksInPath().standardizedFileURL.path else { return nil }
        return target
    }

    /// Review files that exist but can't be read (merge conflict markers, a status from
    /// a newer version, a hand edit) — `all()` and `find()` skip them, so callers that
    /// list comments should say so instead of reporting "no comments".
    func unreadableScenes() -> [(scene: String, error: String)] {
        scenes().compactMap { scene in
            do { _ = try load(scene: scene); return nil } catch { return (scene, "\(error)") }
        }
    }

    /// Adds an attachment to the comment itself. A comment has one `.before` frame,
    /// so a new one replaces the old.
    @discardableResult
    func attach(scene: String, id: String, _ attachment: ReviewAttachment) throws -> ReviewComment {
        try update(scene: scene, id: id) { c in
            var list = c.attachments ?? []
            if attachment.kind == .before { list.removeAll { $0.kind == .before } }
            list.append(attachment)
            c.attachments = list
        }
    }

    /// Deletes a comment plus the attachment files it and its replies reference.
    func remove(scene: String, id: String) throws {
        let comment = try load(scene: scene).comments.first { $0.id == id }
        try delete(scene: scene, id: id)
        guard let comment else { return }
        let paths = (comment.attachments ?? []).map(\.path) + comment.replies.flatMap { $0.attachments.map(\.path) }
        for p in paths {
            // Only regular files directly inside attachments/ — never a directory, never
            // anything a crafted path ("attachments/../../x") points at.
            guard let target = containedAttachmentURL(p),
                  let type = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.type] as? FileAttributeType,
                  type == .typeRegular else { continue }
            try? FileManager.default.removeItem(at: target)
        }
    }

    /// Short git revision of the project, "+dirty" when tracked files changed; nil outside git.
    func currentRevision() -> String? {
        guard let r = try? ProcessRunner.run("/usr/bin/env", ["git", "rev-parse", "--short", "HEAD"], cwd: project.root),
              r.status == 0 else { return nil }
        let sha = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sha.isEmpty else { return nil }
        let dirty = (try? ProcessRunner.run("/usr/bin/env", ["git", "status", "--porcelain", "--untracked-files=no"],
                                            cwd: project.root)).map { $0.status == 0 && !$0.stdout.isEmpty } ?? false
        return dirty ? sha + "+dirty" : sha
    }
}
