import XCTest
@testable import SwiftRenderKit

final class KitTests: XCTestCase {
    private func tempProject() throws -> Project {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sr-kit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "// swift-tools-version: 5.10\n".write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        return Project(root: dir)
    }

    func testReviewRoundTripAndStatus() throws {
        let project = try tempProject()
        let store = ReviewStore(project: project)
        let c = try store.add(scene: "Hello", ReviewComment(t: 2.5, region: ReviewRegion(x: 0.1, y: 0.2, w: 0.3, h: 0.4),
                                                            body: "title lands early", author: ReviewAuthor(name: "Sky")))
        try store.add(scene: "Hello", ReviewComment(t: 1.0, body: "earlier note", author: ReviewAuthor(name: "Sky")))
        try store.setStatus(scene: "Hello", id: c.id, .inProgress, by: .agent())
        try store.reply(scene: "Hello", id: c.id, ReviewReply(author: .agent(), body: "moved the title to 0.6s",
                                                              attachments: [ReviewAttachment(kind: .after, path: "x.png", t: 2.5)]))
        try store.setStatus(scene: "Hello", id: c.id, .resolved, resolution: "delayed title")

        let file = try store.load(scene: "Hello")
        XCTAssertEqual(file.comments.map(\.t), [1.0, 2.5], "comments are kept sorted by time")
        let resolved = try XCTUnwrap(file.comments.first { $0.id == c.id })
        XCTAssertEqual(resolved.status, .resolved)
        XCTAssertNil(resolved.assignee)
        XCTAssertEqual(resolved.replies.count, 1)
        XCTAssertEqual(resolved.region, ReviewRegion(x: 0.1, y: 0.2, w: 0.3, h: 0.4))
        XCTAssertEqual(store.scenes(), ["Hello"])
        XCTAssertEqual(store.all(status: [.open]).count, 1)
        XCTAssertEqual(store.find(id: c.id)?.scene, "Hello")
        XCTAssertThrowsError(try store.setStatus(scene: "Hello", id: "nope", .resolved))
    }

    func testKnobFileRoundTrip() throws {
        let project = try tempProject()
        let url = project.knobsURL(scene: "Hello")
        try KnobFile.save(["delay": .number(0.6), "accent": .string("#C7FF1A"), "grid": .bool(true)], to: url)
        XCTAssertEqual(KnobFile.load(url), ["delay": .number(0.6), "accent": .string("#C7FF1A"), "grid": .bool(true)])
        try KnobFile.save([:], to: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "empty overrides delete the file")
    }

    func testDiagnosticsParseAndDedupe() {
        let log = """
        /x/Sources/SwiftRender/Scenes/Hello.swift:12:9: error: cannot find 'foo' in scope
         10 |     let a = 1
            |         `- error: cannot find 'foo' in scope
        /x/Sources/SwiftRender/Scenes/Hello.swift:12:9: error: cannot find 'foo' in scope
        /x/Sources/SwiftRender/Scenes/Hello.swift:3:1: warning: unused variable [#group]
        [3/9] Compiling SwiftRender Hello.swift
        """
        let d = CompilerDiagnostic.parse(log)
        XCTAssertEqual(d.count, 2)
        XCTAssertEqual(d[0].severity, .error)
        XCTAssertEqual(d[0].line, 12)
        XCTAssertEqual(d[0].column, 9)
        XCTAssertEqual(d[1].severity, .warning)
    }

    func testHostStreamDecoderHandlesBinaryPayloadsAcrossChunks() throws {
        let header = HostMessage(event: "frame", streamID: 7,
                                 frame: HostFrame(t: 0.5, width: 2, height: 1, format: "bgra8", data: "", ms: 1, index: 30, bytes: 8))
        let ready = HostMessage.ready(scenes: [], version: "0.9.0")
        var bytes = try HostWire.encode(ready)
        bytes += try HostWire.encode(header)
        bytes += Data([1, 2, 3, 4, 5, 6, 7, 8])
        bytes += try HostWire.encode(HostMessage.log("after"))

        var decoder = HostStreamDecoder()
        var got: [(HostMessage, Data?)] = []
        for i in stride(from: 0, to: bytes.count, by: 5) {      // feed in awkward 5-byte chunks
            got += try decoder.feed(bytes.subdata(in: i..<min(bytes.count, i + 5)))
        }
        XCTAssertEqual(got.count, 3)
        XCTAssertEqual(got[0].0.event, "ready")
        XCTAssertEqual(got[1].0.frame?.index, 30)
        XCTAssertEqual(got[1].1, Data([1, 2, 3, 4, 5, 6, 7, 8]))
        XCTAssertEqual(got[2].0.message, "after")
    }

    func testProjectDiscoveryPrefersMarkerFile() throws {
        let outer = try tempProject()
        let inner = outer.root.appendingPathComponent("Launch/Sources/LaunchScenes", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try #"{"product":"launch","scenesDir":"Sources/LaunchScenes"}"#
            .write(to: outer.root.appendingPathComponent("Launch/swift-render.json"), atomically: true, encoding: .utf8)
        let found = try XCTUnwrap(Project.discover(from: inner))
        XCTAssertEqual(found.root.lastPathComponent, "Launch")
        XCTAssertEqual(found.config.product, "launch")
        XCTAssertEqual(Project.discover(from: outer.root)?.config.product, "swift-render")
    }
}
