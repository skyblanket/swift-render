import CoreGraphics
import XCTest
import SwiftRenderKit
@testable import SwiftRenderStudio

/// Region math, filters, comment context, controller writes, live reload of external
/// edits, lane retiming and the A/B diff — everything in the review UI that isn't pixels.
@MainActor
final class ReviewUITests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sr-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".swift-render/reviews"),
                                                withIntermediateDirectories: true)
        try "// swift-tools-version: 5.10".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func controller(scene: String = "Demo") -> ReviewController {
        let r = ReviewController(project: Project(root: root))
        r.authorName = "Sky"
        r.revisionLookup = { _ in "abc1234+dirty" }
        r.load(scene: scene)
        return r
    }

    // MARK: Region normalization

    /// A 16:9 canvas letterboxed inside a taller viewer (offset 100 pt down).
    private let canvas = CGRect(x: 20, y: 100, width: 960, height: 540)

    func testRegionNormalizesReversedDragsInsideTheLetterbox() {
        // Dragged bottom-right → top-left, in view coordinates.
        let r = RegionMath.normalize(RegionTool.dragRect(CGPoint(x: 500, y: 370), CGPoint(x: 260, y: 154)), in: canvas)
        XCTAssertEqual(r, ReviewRegion(x: 0.25, y: 0.1, w: 0.25, h: 0.4))
        // Round trip back to the view.
        XCTAssertEqual(RegionMath.rect(r, in: canvas), CGRect(x: 260, y: 154, width: 240, height: 216))
        // In scene points on a 1920×1080 canvas.
        XCTAssertEqual(RegionMath.scenePoints(r, sceneSize: CGSize(width: 1920, height: 1080)),
                       CGRect(x: 480, y: 108, width: 480, height: 432))
    }

    func testRegionClampsToTheFrameAndPointsHaveNoSize() {
        // Starts in the letterbox above-left, ends past the right edge.
        let r = RegionMath.normalize(CGRect(x: 0, y: 40, width: 2000, height: 330), in: canvas)
        XCTAssertEqual(r.x, 0); XCTAssertEqual(r.y, 0); XCTAssertEqual(r.w, 1)
        XCTAssertEqual(r.h, 0.5, accuracy: 1e-4)
        let p = RegionMath.point(CGPoint(x: 980, y: 640), in: canvas)
        XCTAssertEqual(p, ReviewRegion(x: 1, y: 1, w: 0, h: 0))
        XCTAssertTrue(RegionMath.isPoint(p))
        XCTAssertEqual(RegionMath.describe(ReviewRegion(x: 0.5, y: 0.25, w: 0, h: 0), sceneSize: CGSize(width: 1920, height: 1080)),
                       "point .500, .250 = 960,270 scene pt")
        // A degenerate canvas never divides by zero.
        XCTAssertEqual(RegionMath.normalize(CGRect(x: 1, y: 1, width: 5, height: 5), in: .zero), ReviewRegion(x: 0, y: 0, w: 0, h: 0))
    }

    func testPinDragKeepsTheRegionWholeAndTheComposerOnScreen() {
        let r = ReviewRegion(x: 0.7, y: 0.1, w: 0.2, h: 0.2)
        XCTAssertEqual(PinsOverlay.moved(r, by: CGSize(width: 480, height: -270), canvas: canvas),
                       ReviewRegion(x: 0.8, y: 0, w: 0.2, h: 0.2))
        XCTAssertEqual(PinsOverlay.moved(r, by: CGSize(width: -96, height: 54), canvas: canvas),
                       ReviewRegion(x: 0.6, y: 0.2, w: 0.2, h: 0.2))

        let size = CGSize(width: 330, height: 150), box = CGSize(width: 1000, height: 700)
        XCTAssertEqual(RegionTool.composerOrigin(anchor: CGRect(x: 100, y: 200, width: 200, height: 100), size: size, container: box),
                       CGPoint(x: 312, y: 200), "right of the rect")
        XCTAssertEqual(RegionTool.composerOrigin(anchor: CGRect(x: 600, y: 200, width: 300, height: 100), size: size, container: box),
                       CGPoint(x: 258, y: 200), "flips left when the right side is short")
        XCTAssertEqual(RegionTool.composerOrigin(anchor: CGRect(x: 0, y: 650, width: 1000, height: 40), size: size, container: box),
                       CGPoint(x: 335, y: 488), "full-width rect near the bottom: above it, never over it")
        XCTAssertEqual(RegionTool.composerOrigin(anchor: CGRect(x: 0, y: 100, width: 1000, height: 400), size: size, container: box),
                       CGPoint(x: 335, y: 512), "below a wide rect")
        XCTAssertNil(RegionTool.composerOrigin(anchor: CGRect(x: 0, y: 0, width: 1000, height: 700), size: size, container: box),
                     "no room beside the rect: the composer docks in the inspector")
    }

    // MARK: Filters

    private func sample() -> [ReviewComment] {
        let sky = ReviewAuthor(name: "Sky"), ana = ReviewAuthor(name: "Ana"), claude = ReviewAuthor.agent()
        var a = ReviewComment(id: "c00000001", t: 1, body: "Logo too small", author: sky)
        var b = ReviewComment(id: "c00000002", t: 2, body: "Caption overlaps", author: ana, status: .inProgress, assignee: claude)
        var c = ReviewComment(id: "c00000003", t: 3, body: "Possible clipping", author: claude, status: .resolved)
        let d = ReviewComment(id: "c00000004", t: 0.5, body: "Fine as is", author: sky, status: .wontFix)
        a.replies = [ReviewReply(author: ana, body: "agree, maybe +20%")]
        b.replies = []
        c.replies = [ReviewReply(author: claude, body: "fixed")]
        return [a, b, c, d]
    }

    func testQueryFiltersBySegmentAuthorKindAndText() {
        let all = sample()
        var q = ReviewQuery()
        XCTAssertEqual(q.apply(all, me: "Sky").map(\.id), ["c00000001", "c00000002"], "default = the Open segment")
        q.segment = .review
        XCTAssertEqual(q.apply(all, me: "Sky").map(\.id), ["c00000003"], "Claude resolved it, nobody signed off")
        q.segment = .done
        XCTAssertEqual(q.apply(all, me: "Sky").map(\.id), ["c00000004"])
        q.segment = .open
        q.author = .agent
        XCTAssertEqual(q.apply(all, me: "Sky").map(\.id), ["c00000002"], "written, claimed or answered by Claude")
        q.author = .people
        XCTAssertEqual(q.apply(all, me: "Sky").map(\.id), ["c00000001", "c00000002"])
        q.author = .mine
        XCTAssertEqual(q.apply(all, me: "Sky").map(\.id), ["c00000001"])
        q.author = .anyone
        q.text = "+20"
        XCTAssertEqual(q.apply(all, me: "Sky").map(\.id), ["c00000001"], "reply text matches")
        q.text = "c0000000"
        XCTAssertEqual(q.apply(all, me: "Sky").count, 4, "search covers every segment")
    }

    func testDisplayStatesMapStatusesOntoSegments() {
        let sky = ReviewAuthor(name: "Sky")
        let s = sample()
        XCTAssertEqual(s.map(CommentState.init), [.open, .claudeOnIt, .readyForReview, .wontFix])
        XCTAssertEqual(s.map { CommentState($0).segment }, [.open, .open, .review, .done])
        var signed = s[2]
        signed.acceptedBy = sky
        XCTAssertEqual(CommentState(signed), .done, "signed off")
        var byPerson = s[0]
        byPerson.status = .resolved
        XCTAssertEqual(CommentState(byPerson), .done, "a person resolving goes straight to Done")
        var answered = s[2]
        answered.replies.append(ReviewReply(author: sky, body: "fine by me"))
        XCTAssertEqual(CommentState(answered), .done, "a person had the last word")
        var noted = s[2]
        noted.replies.append(ReviewReply(author: ReviewAuthor(name: "Studio", kind: .agent), body: "back on your list"))
        XCTAssertEqual(CommentState(noted), .readyForReview, "Studio's own notes don't count")
    }

    func testMarkDoneResolvesAndSignsOff() async throws {
        let r = controller()
        let c = try await r.add(t: 1, end: nil, region: nil, body: "tidy the logo")
        try r.markDone(c.id, resolution: "nudged it")
        let done = try XCTUnwrap(r.comments.first)
        XCTAssertEqual(done.status, .resolved)
        XCTAssertEqual(done.acceptedBy?.name, "Sky")
        XCTAssertEqual(done.resolution, "nudged it")
        XCTAssertEqual(CommentState(done), .done)
        r.open(c.id)
        XCTAssertTrue(r.threadOpen)
        XCTAssertEqual(r.query.segment, .done, "opening a thread shows its segment")
    }

    func testNumberingFollowsCreationOrder() {
        var all = sample()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        for i in all.indices { all[i].createdAt = t0.addingTimeInterval(Double(i)) }
        let n = ReviewController.numbering(all)
        XCTAssertEqual(n["c00000001"], 1)
        XCTAssertEqual(n["c00000004"], 4, "posted last: number 4, though it's earliest in the scene")
        all[0].t = 9
        XCTAssertEqual(ReviewController.numbering(all)["c00000001"], 1, "retiming keeps the number")
    }

    // MARK: Comment context

    private func clip(_ id: String, _ a: Double, _ b: Double, depth: Int, _ s: SourceLocation) -> ClipInfo {
        ClipInfo(id: id, label: nil, start: a, end: b, depth: depth, pinned: false,
                 transitionIn: "cut", transitionDuration: 0, source: s)
    }

    private func info() -> SceneInfo {
        let src = { (l: Int) in SourceLocation(file: "/p/Sources/Demo.swift", line: l) }
        var i = SceneInfo(name: "Demo", kind: .render, duration: 10, width: 1080, height: 1920, fps: 30,
                          clips: [clip("a", 0, 5, depth: 0, src(20)), clip("b", 2, 3, depth: 1, src(42))])
        i.sourcePath = "/p/Sources/Demo.swift"
        return i
    }

    func testMakeCommentRecordsCanvasInnermostClipRevisionAndContext() throws {
        let ctx = ReviewFrameContext(info: info(), knobs: ["title.delay": .number(0.4)], propsJSON: #"{"a":1}"#,
                                     aspect: "9:16", generation: 7)
        let c = ReviewController.makeComment(t: 2.5, end: 12, region: ReviewRegion(x: 0.9, y: 0.5, w: 0.3, h: 0.2),
                                             body: "x", author: ReviewAuthor(name: "Sky"), context: ctx, revision: "abc1234")
        XCTAssertEqual(c.canvas, ReviewCanvas(width: 1080, height: 1920, fps: 30))
        XCTAssertEqual(c.source?.line, 42, "innermost clip at t")
        XCTAssertEqual(c.revision, "abc1234")
        XCTAssertEqual(c.end, 10, "range end clamped to the scene")
        XCTAssertEqual(c.region!.x + c.region!.w, 1, accuracy: 1e-9, "region clamped to the frame")
        XCTAssertEqual(c.context?["knobs"], #"{"title.delay":0.4}"#)
        XCTAssertEqual(c.context?["aspect"], "9:16")
        XCTAssertEqual(c.context?["build"], "gen 7")
        XCTAssertEqual(c.context?["propsSHA"]?.count, 12)
        XCTAssertNil(c.context?["duration"], "default-length scenes don't pin a duration")

        // Outside every clip: the scene file; a zero-length range is a point.
        let d = ReviewController.makeComment(t: 7, end: 7, region: nil, body: "y", author: ReviewAuthor(name: "Sky"),
                                             context: ReviewFrameContext(info: info()), revision: nil)
        XCTAssertEqual(d.source, SourceLocation(file: "/p/Sources/Demo.swift", line: 1))
        XCTAssertNil(d.end)
        XCTAssertNil(d.context)
    }

    func testMentionsAgent() {
        XCTAssertTrue(ReviewController.mentionsAgent("@claude can you fix this"))
        XCTAssertTrue(ReviewController.mentionsAgent("looks off — @Claude?"))
        XCTAssertFalse(ReviewController.mentionsAgent("mail me@claude.ai"))
        XCTAssertFalse(ReviewController.mentionsAgent("@claudette"))
    }

    // MARK: Controller writes

    func testPostingCapturesTheBeforeStillAndSelectsTheComment() async throws {
        let r = controller()
        r.frameContext = { ReviewFrameContext(info: self.info(), generation: 3) }
        var captured: [(Double, URL)] = []
        r.captureStill = { t, url in
            captured.append((t, url))
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
        }
        r.beginComment(t: 2.5, region: ReviewRegion(x: 0.1, y: 0.1, w: 0.2, h: 0.2))
        r.draft?.body = "ignored — postDraft takes the text"
        let c = try await r.postDraft(body: "  logo too small  ")
        XCTAssertNil(r.draft)
        XCTAssertEqual(c?.body, "logo too small")
        XCTAssertEqual(r.selection, c?.id)
        XCTAssertEqual(captured.first?.0, 2.5)
        let before = try XCTUnwrap(r.comments.first?.beforeAttachment)
        XCTAssertEqual(before.path, ReviewAttachmentPaths.before(c!.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.url(before).path))
        XCTAssertEqual(r.comments.first?.revision, "abc1234+dirty")
        XCTAssertEqual(r.comments.first?.context?["build"], "gen 3")
        XCTAssertEqual(r.openCounts["Demo"], 1)
    }

    func testAFailedStillStillPostsTheComment() async throws {
        let r = controller()
        r.captureStill = { _, _ in throw ReviewError.io("host gone") }
        let c = try await r.add(t: 1, end: nil, region: nil, body: "note")
        XCTAssertNil(c.attachments)
        XCTAssertEqual(r.comments.map(\.id), [c.id])
        XCTAssertTrue(r.lastError?.contains("host gone") ?? false)
    }

    func testThreadActions() async throws {
        let r = controller()
        let c = try await r.add(t: 1, end: 2, region: nil, body: "drags")
        try r.reply(c.id, "@claude trim 0.3 s please")
        XCTAssertTrue(r.agentQueue.contains(c.id))
        try r.setStatus(c.id, .resolved, resolution: "trimmed")
        XCTAssertFalse(r.agentQueue.contains(c.id), "a closed thread leaves the queue")
        try r.accept(c.id)
        XCTAssertEqual(r.selected?.acceptedBy?.name, "Sky")
        try r.reopen(c.id, note: "still drags at 1.8")
        let s = try XCTUnwrap(r.comments.first)
        XCTAssertEqual(s.status, .open)
        XCTAssertNil(s.acceptedBy)
        XCTAssertEqual(s.replies.map(\.body), ["@claude trim 0.3 s please", "still drags at 1.8"])

        try r.retime(c.id, t: 9.5, end: 12, duration: 10)
        XCTAssertEqual(r.comments.first?.t, 9.5)
        XCTAssertEqual(r.comments.first?.end, 10)
        try r.moveRegion(c.id, to: ReviewRegion(x: -0.1, y: 0.5, w: 0.3, h: 0.2))
        XCTAssertEqual(r.comments.first?.region, ReviewRegion(x: 0, y: 0.5, w: 0.2, h: 0.2))
        try r.editBody(c.id, "  ")
        XCTAssertEqual(r.comments.first?.body, "drags", "blank edits are ignored")
    }

    func testDeleteRemovesAttachmentFiles() async throws {
        let r = controller()
        r.captureStill = { _, url in try Data([1]).write(to: url) }
        let c = try await r.add(t: 1, end: nil, region: nil, body: "x")
        let url = r.url(try XCTUnwrap(r.comments.first?.beforeAttachment))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        r.selection = c.id
        try r.delete(c.id)
        XCTAssertTrue(r.comments.isEmpty)
        XCTAssertNil(r.selection)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// The real watcher → reload path, with another writer (CLI/MCP/agent) on the file.
    func testExternalEditsAppearWithin300ms() async throws {
        let r = controller()
        let w = FileWatcher(root: root) { changes in
            Task { @MainActor in if changes.contains(where: { $0.kind == .review }) { r.reload() } }
        }
        w.start()
        defer { w.stop() }
        try await Task.sleep(for: .milliseconds(300))    // FSEvents needs a moment before the first write counts

        let other = ReviewStore(project: Project(root: root))
        var samples: [Double] = []
        for i in 0..<3 {
            let c = ReviewComment(t: Double(i), body: "from the CLI \(i)", author: .agent())
            let t0 = Date()
            try other.add(scene: "Demo", c)
            await waitUntil(2, "comment \(i) to appear") { r.comments.contains { $0.id == c.id } }
            samples.append(Date().timeIntervalSince(t0))
            try await Task.sleep(for: .milliseconds(100))
        }
        let median = samples.sorted()[1]
        print(String(format: "[review] external edit → Studio: %@ s (median %.3f)",
                     samples.map { String(format: "%.3f", $0) }.joined(separator: " / "), median))
        XCTAssertLessThanOrEqual(median, 0.3)
    }

    // MARK: Lane retiming

    func testRetimeSnapsToFramesAndStaysInsideTheScene() {
        // The timeline's RetimeMath is the one drag model; ReviewController.retimed
        // is the store-side clamp.
        typealias R = RetimeMath
        // Move a range by +0.51 s at 30 fps: snapped to the frame grid, length kept.
        let (t, e) = R.apply(.body, t: 1, end: 2, delta: 0.51, duration: 10, fps: 30)
        XCTAssertEqual(t, 1.5, accuracy: 1e-9); XCTAssertEqual(e!, 2.5, accuracy: 1e-9)
        // Past the end: the whole range stays inside.
        let (t2, e2) = R.apply(.body, t: 8, end: 9, delta: 5, duration: 10, fps: 30)
        XCTAssertEqual(t2, 9, accuracy: 1e-9); XCTAssertEqual(e2!, 10, accuracy: 1e-9)
        // Start can't cross the end (one frame minimum), end can't cross the start.
        XCTAssertEqual(R.apply(.startHandle, t: 1, end: 2, delta: 3, duration: 10, fps: 30).t, 2 - 1.0 / 30, accuracy: 1e-9)
        XCTAssertEqual(R.apply(.endHandle, t: 1, end: 2, delta: -3, duration: 10, fps: 30).end!, 1 + 1.0 / 30, accuracy: 1e-9)
        // A point comment dragged by its "start" just moves.
        let p = R.apply(.startHandle, t: 1, end: nil, delta: -2, duration: 10, fps: 30)
        XCTAssertEqual(p.t, 0); XCTAssertNil(p.end)
        XCTAssertEqual(ReviewController.retimed(t: 3, end: 2, duration: 10).1!, 3 + 1.0 / 60, accuracy: 1e-9)
    }

    func testLaneHitsHandlesAndPrefersMarkers() {
        var v = TimelineViewport()
        v.start = 0; v.pxPerSecond = 100; v.width = 1000; v.duration = 10
        let range = ReviewComment(id: "r", t: 1, end: 3, body: "", author: ReviewAuthor(name: "Sky"))
        let point = ReviewComment(id: "p", t: 2, body: "", author: ReviewAuthor(name: "Sky"))
        let lane = CommentsLane(comments: [range, point], selection: nil)
        let mid = lane.height / 2
        XCTAssertEqual(lane.hit(CGPoint(x: 299, y: mid), viewport: v)?.id, "r")
        XCTAssertEqual(lane.hit(CGPoint(x: 299, y: mid), viewport: v)?.part, .endHandle)
        XCTAssertEqual(lane.hit(CGPoint(x: 101, y: mid), viewport: v)?.part, .startHandle)
        XCTAssertEqual(lane.hit(CGPoint(x: 203, y: mid), viewport: v)?.id, "p", "markers win over range bodies")
        XCTAssertEqual(lane.hit(CGPoint(x: 250, y: mid), viewport: v)?.part, .body)
        XCTAssertNil(lane.hit(CGPoint(x: 600, y: mid), viewport: v))
    }

    // MARK: A/B diff

    private func solid(_ w: Int, _ h: Int, split: Double? = nil) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if let split {
            ctx.setFillColor(CGColor(gray: 0.9, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: Double(w) * split, height: Double(h)))
        }
        return ctx.makeImage()!
    }

    func testChangedFractionAndDifference() throws {
        let a = solid(640, 360), b = solid(640, 360, split: 0.25)
        XCTAssertEqual(CompareMath.changedFraction(a, a), 0)
        XCTAssertEqual(CompareMath.changedFraction(a, b), 0.25, accuracy: 0.02)
        XCTAssertEqual(CompareMath.changedFraction(a, solid(1280, 720, split: 0.5)), 0.5, accuracy: 0.02,
                       "different sizes compare on the same grid")
        XCTAssertEqual(CompareMath.label(0), "No visible change in this frame")
        XCTAssertEqual(CompareMath.label(0.0004), "Less than 1% of the frame changed")
        XCTAssertEqual(CompareMath.label(0.123), "12% of the frame changed")

        let d = try XCTUnwrap(CompareMath.difference(a, b))
        XCTAssertEqual(d.width, 640)
        let l = CompareMath.luma(d, width: 4, height: 1)
        XCTAssertGreaterThan(l[0], 0.9, "changed quarter: |0.9−0.2|×4, clipped to white")
        XCTAssertLessThan(l[3], 0.02, "unchanged area stays black")
    }
}
