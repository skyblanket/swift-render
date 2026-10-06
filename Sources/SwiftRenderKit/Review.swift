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

    public static func format(_ t: Double) -> String {
        String(format: "%02d:%05.2f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }
}

public struct ReviewCanvas: Codable, Sendable, Equatable, Hashable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public init(width: Int, height: Int, fps: Int) { self.width = width; self.height = height; self.fps = fps }
}

public enum ReviewAttachmentPaths {
    /// `.swift-render/attachments/<commentID>-before.png` (project-relative).
    public static func before(_ commentID: String) -> String { ".swift-render/attachments/\(commentID)-before.png" }
    /// `.swift-render/attachments/<commentID>-after-<replyID>.png` (project-relative).
    public static func after(_ commentID: String, reply replyID: String) -> String {
        ".swift-render/attachments/\(commentID)-after-\(replyID).png"
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
        let lockURL = project.reviewsDir.appendingPathComponent(".\(scene).lock")
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
            file.comments[i].status = status
            file.comments[i].assignee = status == .inProgress ? author : nil
            if let resolution { file.comments[i].resolution = resolution }
            file.comments[i].updatedAt = Date()
            return file.comments[i]
        }
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
