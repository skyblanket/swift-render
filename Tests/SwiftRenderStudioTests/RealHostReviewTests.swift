import CoreGraphics
import XCTest
import SwiftRenderKit
@testable import SwiftRenderStudio

/// Posting a comment against the real `serve` host on this repo: the `.before` still
/// comes from host `still` at full resolution, the comment records canvas / innermost
/// clip / revision, and the A/B "live" frame for the same t matches the still (scenes
/// are pure functions of t, so Δ must be ~0). The comment and its PNG are deleted.
/// Runs a real build, so opt-in:
///
///   SR_STUDIO_REAL_E2E=1 swift test --filter RealHostReviewTests
@MainActor
final class RealHostReviewTests: XCTestCase {
    func testPostCapturesBeforeStillAndLiveCompareMatches() async throws {
        guard ProcessInfo.processInfo.environment["SR_STUDIO_REAL_E2E"] == "1" else {
            throw XCTSkip("set SR_STUDIO_REAL_E2E=1 to run real builds against this repo")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        // Leave no review file behind when there wasn't one.
        let reviewFile = Project.open(root).reviewURL(scene: "TimelineDemo")
        if !FileManager.default.fileExists(atPath: reviewFile.path) {
            addTeardownBlock { try? FileManager.default.removeItem(at: reviewFile) }
        }
        var options = LaunchOptions()
        options.scene = "TimelineDemo"
        options.at = 3
        let model = ProjectModel(root: root, options: options)
        model.playback.displayWidth = 480
        await model.start()
        await waitUntil(600, "build + host + frame") {
            if case .ready = model.host.state { return model.playback.hasFrame && model.info != nil }
            return false
        }

        let r = model.review
        let t0 = Date()
        let c = try await r.add(t: 3, end: nil, region: ReviewRegion(x: 0.1, y: 0.3, w: 0.5, h: 0.4),
                                body: "RealHostReviewTests probe")
        defer { try? r.delete(c.id) }
        print(String(format: "[review] post with full-res before still: %.0f ms", Date().timeIntervalSince(t0) * 1000))

        XCTAssertNil(r.lastError)
        let before = try XCTUnwrap(c.beforeAttachment, "before still attached")
        let img = try ReviewImage.load(r.url(before))
        XCTAssertEqual(img.width, 1920); XCTAssertEqual(img.height, 1080)
        XCTAssertEqual(c.canvas, ReviewCanvas(width: 1920, height: 1080, fps: model.info?.fps ?? 60))
        XCTAssertTrue(c.source?.file.hasSuffix("TimelineDemo.swift") ?? false, "innermost clip source: \(String(describing: c.source))")
        XCTAssertNotNil(c.revision)
        XCTAssertNotNil(c.context?["build"])
        let luma = CompareMath.luma(img)
        let mean = luma.reduce(0, +) / Double(luma.count)
        XCTAssertGreaterThan(luma.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(luma.count), 1e-4, "not a blank frame")

        // A/B live path: same t from the active host.
        let host = try XCTUnwrap(model.host.active)
        let live = try await host.frame(t: c.t, maxWidth: img.width, format: host.supportsBinaryFrames ? .bgra8 : .png)
        let delta = CompareMath.changedFraction(img, live.image)
        print(String(format: "[review] before vs live at t=%.2f: %@", c.t, CompareMath.label(delta)))
        XCTAssertLessThan(delta, 0.005)

        try r.delete(c.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.url(before).path))
        await model.shutdown()
    }
}
