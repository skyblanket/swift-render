import Foundation
import Observation
import SwiftRenderKit

// MARK: - Review controller   // S6
//
// Comments for the selected scene, read from `.swift-render/reviews/<Scene>.json`
// (reloaded by the file watcher, so CLI/MCP/agent edits appear live) and written
// only through `ReviewStore` (flock + atomic rename). Shell: load/add/reply/status
// work; S6 adds before-frame capture (`still`), canvas/source/revision context,
// `@claude` queueing, retiming, and the composer UI.

enum ReviewFilter: String, CaseIterable, Identifiable, Sendable {
    case open, mine, agent, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .open: return "Open"
        case .mine: return "Mine"
        case .agent: return "Agent"
        case .all: return "All"
        }
    }
}

/// A comment being composed (C key, region tool, clip context menu).
struct CommentDraft: Equatable, Sendable {
    var t: Double
    var end: Double?
    var region: ReviewRegion?
    var body = ""
}

@MainActor @Observable
final class ReviewController {
    let project: Project
    private(set) var scene: String?
    private(set) var comments: [ReviewComment] = []
    var filter: ReviewFilter = .open
    var selection: String?
    /// Non-nil while the composer is open.
    var draft: CommentDraft?
    private(set) var lastError: String?
    /// Open-comment counts per scene (sidebar badges).
    private(set) var openCounts: [String: Int] = [:]

    @ObservationIgnored private let store: ReviewStore
    @ObservationIgnored lazy var authorName: String = project.defaultAuthorName()
    /// Called after comments change (playback pins, timeline lane).
    @ObservationIgnored var onChange: (([ReviewComment]) -> Void)?

    init(project: Project) {
        self.project = project
        self.store = ReviewStore(project: project)
    }

    var filtered: [ReviewComment] {
        switch filter {
        case .open: return comments.filter { $0.status.isActive }
        case .mine: return comments.filter { $0.author.name == authorName }
        case .agent: return comments.filter { $0.author.kind == .agent || $0.assignee?.kind == .agent }
        case .all: return comments
        }
    }

    var openCount: Int { comments.filter { $0.status == .open }.count }
    var inProgressCount: Int { comments.filter { $0.status == .inProgress }.count }
    var selected: ReviewComment? { comments.first { $0.id == selection } }

    func load(scene: String?) {
        self.scene = scene
        reload()
    }

    /// Re-read from disk (watcher: `.swift-render/reviews/*.json` changed).
    func reload() {
        var counts: [String: Int] = [:]
        for (s, _) in store.all(status: [.open, .inProgress]) { counts[s, default: 0] += 1 }
        openCounts = counts
        guard let scene else { comments = []; onChange?([]); return }
        do {
            let file = try store.load(scene: scene)
            if file.comments != comments { comments = file.comments }
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
        onChange?(comments)
    }

    /// Open the composer at the playhead (C), as a range when in/out is set.
    func beginComment(t: Double, end: Double? = nil, region: ReviewRegion? = nil) {
        draft = CommentDraft(t: t, end: end, region: region)
    }

    // S6: capture the before-frame via host `still`, record canvas/source/revision/context.
    @discardableResult
    func add(t: Double, end: Double?, region: ReviewRegion?, body: String) async throws -> ReviewComment {
        guard let scene else { throw ReviewError.io("no scene selected") }
        let c = ReviewComment(t: t, end: end, region: region, body: body, author: ReviewAuthor(name: authorName))
        try store.add(scene: scene, c)
        reload()
        selection = c.id
        return c
    }

    func reply(_ id: String, _ body: String) throws {
        guard let scene else { return }
        try store.reply(scene: scene, id: id, ReviewReply(author: ReviewAuthor(name: authorName), body: body))
        reload()
    }

    func setStatus(_ id: String, _ s: ReviewStatus, resolution: String? = nil) throws {
        guard let scene else { return }
        try store.setStatus(scene: scene, id: id, s, by: ReviewAuthor(name: authorName), resolution: resolution)
        reload()
    }

    func accept(_ id: String) throws {
        guard let scene else { return }
        let me = ReviewAuthor(name: authorName)
        try store.update(scene: scene, id: id) { $0.acceptedBy = me }
        reload()
    }

    /// `[` / `]`: previous/next comment by time; returns its time to seek to.
    func selectAdjacent(next: Bool, from t: Double) -> Double? {
        let sorted = comments.sorted { $0.t < $1.t }
        let pick = next ? sorted.first { $0.t > t + 1e-3 } : sorted.last { $0.t < t - 1e-3 }
        guard let pick else { return nil }
        selection = pick.id
        return pick.t
    }
}
