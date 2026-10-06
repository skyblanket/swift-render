import AppKit
import CryptoKit
import Foundation
import Observation
import SwiftRenderKit

// MARK: - Review controller
//
// Comments for the selected scene, read from `.swift-render/reviews/<Scene>.json`
// (reloaded by the file watcher, so CLI/MCP/agent edits appear within ~250 ms) and
// written only through `ReviewStore` (flock + atomic rename). A new comment carries
// what an agent needs to reproduce the frame: the `.before` still from the host,
// canvas, innermost clip source, git revision and knob/props context.

/// The comments list's three segments. Each display state belongs to exactly one.
enum ReviewSegment: String, CaseIterable, Identifiable, Sendable {
    /// Open, In Progress, Claude's on it.
    case open
    /// Ready for Review: Claude resolved it and nobody has signed off yet.
    case review
    /// Done and Won't Fix.
    case done
    var id: String { rawValue }
    var title: String {
        switch self {
        case .open: return "Open"
        case .review: return "Review"
        case .done: return "Done"
        }
    }
}

/// Who wrote (or is working on) a comment.
enum AuthorFilter: String, CaseIterable, Identifiable, Sendable {
    case anyone, mine, people, agent
    var id: String { rawValue }
    var title: String {
        switch self {
        case .anyone: return "Everyone"
        case .mine: return "Me"
        case .people: return "People"
        case .agent: return "Claude"
        }
    }
}

/// What the comments list shows: one segment, an author kind and free text. Text
/// searches every segment.
struct ReviewQuery: Equatable, Sendable {
    var segment: ReviewSegment = .open
    var author: AuthorFilter = .anyone
    var text = ""

    /// Comments that pass, in scene order.
    func apply(_ comments: [ReviewComment], me: String) -> [ReviewComment] {
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        return comments.filter { c in
            if needle.isEmpty, CommentState(c).segment != segment { return false }
            switch author {
            case .anyone: break
            case .people: if c.author.kind != .human { return false }
            case .agent: if !ReviewQuery.involvesAgent(c) { return false }
            case .mine: if c.author.name != me || c.author.kind != .human { return false }
            }
            guard !needle.isEmpty else { return true }
            if c.id.lowercased().hasPrefix(needle) || c.body.lowercased().contains(needle) { return true }
            return c.replies.contains { $0.body.lowercased().contains(needle) }
        }
    }

    /// Written by, assigned to, or answered by an agent.
    static func involvesAgent(_ c: ReviewComment) -> Bool {
        c.author.kind == .agent || c.assignee?.kind == .agent || c.replies.contains { $0.author.kind == .agent }
    }
}

/// A comment being composed (C key, region tool, timeline, toolbar).
struct CommentDraft: Equatable, Sendable {
    var t: Double
    var end: Double?
    var region: ReviewRegion?
    var body = ""
    /// Where the composer shows: next to the region in the viewer, else in the inspector.
    var anchoredInViewer: Bool { region != nil }
}

/// Everything `add` records about the frame being commented on, taken at post time.
struct ReviewFrameContext: Sendable {
    var info: SceneInfo?
    var knobs: [String: KnobValue] = [:]
    var propsJSON: String?
    var aspect: String?
    var generation: Int?
}

@MainActor @Observable
final class ReviewController {
    let project: Project
    private(set) var scene: String?
    private(set) var comments: [ReviewComment] = []
    var query = ReviewQuery()
    var selection: String?
    /// The selected comment's thread fills the Comments tab (pushed over the list).
    var threadOpen = false
    /// Non-nil while the composer is open.
    var draft: CommentDraft? { didSet { if draft?.region == nil { draftDocked = false } } }
    /// A region draft with no room beside its spot in the viewer: the composer docks in
    /// the Comments tab.
    var draftDocked = false
    /// The comment A/B compare shows (its `.before` against the latest after / live).
    var compareID: String?
    /// Threads a reply mentioned `@claude` in: the next Ask Claude pre-selects them.
    private(set) var agentQueue: Set<String> = []
    private(set) var lastError: String?
    /// Open + in-progress counts per scene (sidebar badges).
    private(set) var openCounts: [String: Int] = [:]
    /// Bumped whenever comments are re-read (thumbnail views key their reloads on it).
    private(set) var revision = 0

    @ObservationIgnored let store: ReviewStore
    @ObservationIgnored lazy var authorName: String = project.defaultAuthorName()
    /// Called after comments change (playback pins, timeline lane).
    @ObservationIgnored var onChange: (([ReviewComment]) -> Void)?
    /// Renders the full-resolution still at `t` to a file (host `still`). nil = no host.
    @ObservationIgnored var captureStill: ((_ t: Double, _ url: URL) async throws -> Void)?
    /// Scene info, knobs, props and build at the moment of posting.
    @ObservationIgnored var frameContext: () -> ReviewFrameContext = { ReviewFrameContext() }
    /// Git revision lookup (a subprocess; tests stub it).
    @ObservationIgnored var revisionLookup: @Sendable (ReviewStore) -> String? = { $0.currentRevision() }
    @ObservationIgnored private var thumbs: [String: (stamp: Date, image: NSImage)] = [:]

    init(project: Project) {
        self.project = project
        self.store = ReviewStore(project: project)
    }

    // MARK: Filters

    var filtered: [ReviewComment] { query.apply(comments, me: authorName) }

    func count(_ s: ReviewStatus) -> Int { comments.filter { $0.status == s }.count }
    func count(segment: ReviewSegment) -> Int { comments.filter { CommentState($0).segment == segment }.count }
    var readyForReviewCount: Int { count(segment: .review) }
    var openCount: Int { count(.open) }
    var inProgressCount: Int { count(.inProgress) }
    var selected: ReviewComment? { comments.first { $0.id == selection } }
    var compared: ReviewComment? { comments.first { $0.id == compareID } }

    /// 1-based position in creation order: the number on pins, lane markers, rows and in
    /// Claude's transcript. Creation order keeps a comment's number when it is retimed.
    func number(of id: String) -> Int? { Self.numbering(comments)[id] }

    nonisolated static func numbering(_ comments: [ReviewComment]) -> [String: Int] {
        let ordered = comments.sorted { ($0.createdAt, $0.t, $0.id) < ($1.createdAt, $1.t, $1.id) }
        return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1.id, $0 + 1) })
    }

    // MARK: Loading

    func load(scene: String?) {
        if scene != self.scene { selection = nil; threadOpen = false; compareID = nil; draft = nil }
        self.scene = scene
        reload()
    }

    /// Re-read from disk (watcher: `.swift-render/reviews/*.json` changed).
    func reload() {
        var counts: [String: Int] = [:]
        for (s, _) in store.all(status: [.open, .inProgress]) { counts[s, default: 0] += 1 }
        if counts != openCounts { openCounts = counts }
        guard let scene else {
            if !comments.isEmpty { comments = [] }
            onChange?([])
            return
        }
        do {
            let file = try store.load(scene: scene)
            if file.comments != comments { comments = file.comments; revision += 1 }
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
        if let s = selection, !comments.contains(where: { $0.id == s }) { selection = nil; threadOpen = false }
        if let c = compareID, !comments.contains(where: { $0.id == c }) { compareID = nil }
        onChange?(comments)
    }

    // MARK: Composing

    /// Open the composer at the playhead (C), as a range when in/out is set.
    func beginComment(t: Double, end: Double? = nil, region: ReviewRegion? = nil) {
        draft = CommentDraft(t: t, end: end, region: region)
    }

    /// Posts the open draft; `askAgent` also queues the new thread for Claude.
    @discardableResult
    func postDraft(body: String, askAgent: Bool = false) async throws -> ReviewComment? {
        guard let d = draft else { return nil }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        draft = nil
        let c = try await add(t: d.t, end: d.end, region: d.region, body: text)
        if askAgent || Self.mentionsAgent(text) { agentQueue.insert(c.id) }
        return c
    }

    /// Writes the comment with its context, then the `.before` still (a failed still
    /// leaves the comment without one rather than losing the note).
    @discardableResult
    func add(t: Double, end: Double?, region: ReviewRegion?, body: String) async throws -> ReviewComment {
        guard let scene else { throw ReviewError.io("no scene selected") }
        let ctx = frameContext()
        let store = self.store, lookup = revisionLookup
        let revision = await Task.detached { lookup(store) }.value
        var c = Self.makeComment(t: t, end: end, region: region, body: body,
                                 author: ReviewAuthor(name: authorName), context: ctx, revision: revision)
        var stillError: String?
        if let capture = captureStill {
            let rel = ReviewAttachmentPaths.before(c.id)
            let url = store.url(forAttachment: rel)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await capture(c.t, url)
                c.attachments = [ReviewAttachment(kind: .before, path: rel, t: c.t)]
            } catch {
                stillError = "Posted, but Studio couldn't save the Before frame (\(error))"
            }
        }
        try store.add(scene: scene, c)
        if query.text.isEmpty { query.segment = .open }
        reload()
        if let stillError { lastError = stillError }
        selection = c.id
        return c
    }

    /// The comment `add` writes, minus the still (pure, tested).
    nonisolated static func makeComment(t: Double, end: Double?, region: ReviewRegion?, body: String, author: ReviewAuthor,
                            context ctx: ReviewFrameContext, revision: String?) -> ReviewComment {
        let duration = ctx.info?.duration
        let t0 = duration.map { min(max(0, t), $0) } ?? max(0, t)
        let e = end.flatMap { e -> Double? in
            let e1 = duration.map { min(e, $0) } ?? e
            return e1 > t0 + 1e-6 ? e1 : nil
        }
        var c = ReviewComment(t: t0, end: e, region: region.map(\.clamped), body: body, author: author)
        if let info = ctx.info {
            c.canvas = ReviewCanvas(width: info.width, height: info.height, fps: info.fps)
            c.source = info.clips(at: t0).last?.source ?? info.sourcePath.map { SourceLocation(file: $0, line: 1) }
        }
        c.revision = revision
        var context: [String: String] = [:]
        // No "duration": Studio renders scenes at their default length, and a pinned
        // duration would stop the agent's after-frame from following a retimed scene.
        if let a = ctx.aspect { context["aspect"] = a }
        if let g = ctx.generation, g > 0 { context["build"] = "gen \(g)" }
        if !ctx.knobs.isEmpty {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            if let data = try? enc.encode(ctx.knobs) { context["knobs"] = String(decoding: data, as: UTF8.self) }
        }
        if let props = ctx.propsJSON, !props.isEmpty {
            let digest = SHA256.hash(data: Data(props.utf8))
            context["propsSHA"] = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        }
        c.context = context.isEmpty ? nil : context
        return c
    }

    /// "@claude" (any case) as a word in a reply or comment.
    nonisolated static func mentionsAgent(_ text: String) -> Bool {
        text.range(of: #"(^|[^\w])@claude\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: Editing

    func reply(_ id: String, _ body: String) throws {
        guard let scene else { return }
        try store.reply(scene: scene, id: id, ReviewReply(author: ReviewAuthor(name: authorName), body: body))
        if Self.mentionsAgent(body) { agentQueue.insert(id) }
        reload()
    }

    func setStatus(_ id: String, _ s: ReviewStatus, resolution: String? = nil) throws {
        guard let scene else { return }
        try store.setStatus(scene: scene, id: id, s, by: ReviewAuthor(name: authorName), resolution: resolution)
        if !s.isActive { agentQueue.remove(id) }
        reload()
    }

    /// Select a comment and show its thread, switching to the segment it lives in.
    func open(_ id: String) {
        guard let c = comments.first(where: { $0.id == id }) else { return }
        selection = id
        threadOpen = true
        if query.text.isEmpty { query.segment = CommentState(c).segment }
    }

    /// A person marks it done: resolved and signed off in one step (no "Looks Good" round).
    func markDone(_ id: String, resolution: String?) throws {
        guard let scene else { return }
        let me = ReviewAuthor(name: authorName)
        let note = resolution?.trimmingCharacters(in: .whitespacesAndNewlines)
        try store.update(scene: scene, id: id) { c in
            c.status = .resolved; c.assignee = nil; c.acceptedBy = me
            if let note, !note.isEmpty { c.resolution = note }
        }
        agentQueue.remove(id)
        reload()
    }

    /// Human sign-off on a resolution (an open or in-progress comment is resolved too).
    func accept(_ id: String) throws {
        guard let scene else { return }
        let me = ReviewAuthor(name: authorName)
        try store.update(scene: scene, id: id) { c in
            c.acceptedBy = me
            if c.status.isActive { c.status = .resolved; c.assignee = nil }
        }
        agentQueue.remove(id)
        reload()
    }

    /// Back to open with a reply saying why; clears any sign-off.
    func reopen(_ id: String, note: String?) throws {
        guard let scene else { return }
        let text = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let me = ReviewAuthor(name: authorName)
        try store.update(scene: scene, id: id) { c in
            c.status = .open; c.assignee = nil; c.acceptedBy = nil
            if !text.isEmpty { c.replies.append(ReviewReply(author: me, body: text)) }
        }
        if Self.mentionsAgent(text) { agentQueue.insert(id) }
        reload()
    }

    /// Drag on the NOTES lane: new start/end, kept inside the scene and in order.
    func retime(_ id: String, t: Double, end: Double?, duration: Double?) throws {
        guard let scene else { return }
        let (t0, e) = Self.retimed(t: t, end: end, duration: duration)
        try store.update(scene: scene, id: id) { c in c.t = t0; c.end = e }
        reload()
    }

    nonisolated static func retimed(t: Double, end: Double?, duration: Double?, minLength: Double = 1.0 / 60) -> (Double, Double?) {
        let maxT = duration ?? .greatestFiniteMagnitude
        let t0 = min(max(0, t), maxT)
        guard let end else { return (t0, nil) }
        let e = min(max(end, t0 + minLength), maxT)
        return e > t0 ? (t0, e) : (t0, nil)
    }

    /// Pin edit (drag the rect): a new normalized region, clamped to the frame.
    func moveRegion(_ id: String, to region: ReviewRegion) throws {
        guard let scene else { return }
        let c = region.clamped
        func r4(_ v: Double) -> Double { (v * 10_000).rounded() / 10_000 }
        let tidy = ReviewRegion(x: r4(c.x), y: r4(c.y), w: r4(c.w), h: r4(c.h))
        try store.update(scene: scene, id: id) { $0.region = tidy }
        reload()
    }

    func editBody(_ id: String, _ body: String) throws {
        guard let scene else { return }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        try store.update(scene: scene, id: id) { $0.body = text }
        reload()
    }

    /// Deletes the comment and its attachment files.
    func delete(_ id: String) throws {
        guard let scene else { return }
        try store.remove(scene: scene, id: id)
        if selection == id { selection = nil; threadOpen = false }
        agentQueue.remove(id)
        reload()
    }

    /// Snapshot fixtures only: change the loaded threads without writing the review file.
    func editInMemory(_ edit: (inout [ReviewComment]) -> Void) {
        edit(&comments)
        revision += 1
        onChange?(comments)
    }

    /// Ask Claude consumed the queue.
    func clearAgentQueue() { agentQueue = [] }

    /// `[` / `]`: previous/next comment by time; returns its time to seek to.
    func selectAdjacent(next: Bool, from t: Double) -> Double? {
        let sorted = comments.sorted { $0.t < $1.t }
        let pick = next ? sorted.first { $0.t > t + 1e-3 } : sorted.last { $0.t < t - 1e-3 }
        guard let pick else { return nil }
        selection = pick.id
        return pick.t
    }

    // MARK: Attachments

    func url(_ a: ReviewAttachment) -> URL { store.url(forAttachment: a.path) }

    /// Thumbnail-sized image for an attachment, cached by path and file date.
    func image(_ a: ReviewAttachment) -> NSImage? {
        let url = url(a)
        guard let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return nil }
        if let hit = thumbs[a.path], hit.stamp == stamp { return hit.image }
        guard let cg = try? ReviewImage.load(url) else { return nil }
        let small = ReviewImage.scaled(cg, maxWidth: 480)
        let img = NSImage(cgImage: small, size: NSSize(width: small.width, height: small.height))
        thumbs[a.path] = (stamp, img)
        return img
    }

    /// Every attachment on a thread: the comment's own, then each reply's, oldest first.
    nonisolated static func attachments(of c: ReviewComment) -> [ReviewAttachment] {
        (c.attachments ?? []) + c.replies.flatMap(\.attachments)
    }
}

// MARK: - Launch options (snapshot verification of the review UI)

extension ProjectModel {
    /// `--comment <id|first|N>` selects a thread, `--compare <mode>` opens A/B on it,
    /// `--draft x,y,w,h` (or `point:x,y`) opens the composer with that region.
    func applyReviewLaunchOptions() {
        let o = options
        let r = review
        if let pick = o.commentSelection {
            // N is the comment's number (creation order), as on its disc.
            let numbers = ReviewController.numbering(r.comments)
            let ordered = r.comments.sorted { (numbers[$0.id] ?? 0) < (numbers[$1.id] ?? 0) }
            let c: ReviewComment?
            switch pick {
            case "first": c = ordered.first
            case "last": c = ordered.last
            default:
                if let n = Int(pick), n >= 1, n <= ordered.count { c = ordered[n - 1] }
                else { c = ordered.first { $0.id.hasPrefix(pick) } }
            }
            if let c {
                r.open(c.id)
                ui.inspectorTab = .comments
                if o.at == nil { playback.seek(c.t, precise: true) }
            }
        }
        if let mode = o.compareMode {
            r.compareID = r.selection ?? r.comments.first { $0.beforeAttachment != nil }?.id
            ui.compare = mode
        }
        if let spec = o.draftRegion {
            let region: ReviewRegion?
            if spec.hasPrefix("point:") {
                let v = spec.dropFirst(6).split(separator: ",").compactMap { Double($0) }
                region = v.count == 2 ? ReviewRegion(x: v[0], y: v[1], w: 0, h: 0) : nil
            } else {
                region = ReviewRegion(parsing: spec)
            }
            r.beginComment(t: o.at ?? playback.t, end: nil, region: region)
            if let text = o.draftText { r.draft?.body = text }
        }
    }
}
