import CoreGraphics
import XCTest
@testable import SwiftRender
@testable import SwiftRenderScenes
@testable import SwiftRenderKit
@testable import SwiftRenderTool

/// The review loop: Kit helpers, `swift-render review`, the MCP server over stdio,
/// and the agent/skill/plugin files that tie them together.
final class ReviewLoopTests: XCTestCase {
    /// The MCP tool names are a contract with Studio and the director agent.
    static let toolNames = ["list_scenes", "scene_info", "render_frames", "contact_sheet", "check_scene", "build",
                            "list_comments", "get_comment", "claim_comment", "reply_comment", "resolve_comment",
                            "set_knobs", "render_video"]

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func tempProject() throws -> Project {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sr-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "// swift-tools-version: 5.10\n".write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return Project(root: dir)
    }

    // MARK: Kit

    func testStatusAndRegionParsing() throws {
        XCTAssertEqual(ReviewStatus(loose: "in-progress"), .inProgress)
        XCTAssertEqual(ReviewStatus(loose: "won't fix"), .wontFix)
        XCTAssertEqual(ReviewStatus(loose: "Resolved"), .resolved)
        XCTAssertNil(ReviewStatus(loose: "maybe"))
        XCTAssertEqual(try ReviewStatus.parseFilter("open, inProgress"), [.open, .inProgress])
        XCTAssertEqual(try ReviewStatus.parseFilter("active"), [.open, .inProgress])
        XCTAssertNil(try ReviewStatus.parseFilter("all"))
        XCTAssertThrowsError(try ReviewStatus.parseFilter("open,bogus"))

        XCTAssertEqual(ReviewRegion(parsing: "0.08, 0.3, 0.5, 0.4"), ReviewRegion(x: 0.08, y: 0.3, w: 0.5, h: 0.4),
                       "in-bounds regions keep their exact values")
        let clipped = try XCTUnwrap(ReviewRegion(parsing: "0.9,-0.1,0.5,0.3"), "partly off-frame regions are clipped")
        for (got, want) in zip([clipped.x, clipped.y, clipped.w, clipped.h], [0.9, 0, 0.1, 0.2]) {
            XCTAssertEqual(got, want, accuracy: 1e-9)
        }
        XCTAssertNil(ReviewRegion(parsing: "0.1,0.2,0,0.3"))
        XCTAssertNil(ReviewRegion(parsing: "1.2,0.2,0.1,0.1"), "entirely off-frame")
        XCTAssertNil(ReviewRegion(parsing: "0.1,0.2,0.3"))
        XCTAssertEqual(ReviewRegion(x: 0.25, y: 0.5, w: 0.5, h: 0.25).pixelRect(width: 1920, height: 1080),
                       CGRect(x: 480, y: 540, width: 960, height: 270))
    }

    func testResolveByPrefixAttachAndRemove() throws {
        let project = try tempProject()
        let store = ReviewStore(project: project)
        let a = try store.add(scene: "Hello", ReviewComment(id: "cabc12345", t: 1, body: "a", author: ReviewAuthor(name: "S")))
        try store.add(scene: "Other", ReviewComment(id: "cabc99999", t: 2, body: "b", author: ReviewAuthor(name: "S")))

        XCTAssertEqual(try store.resolve(id: "cabc12345").scene, "Hello")
        XCTAssertEqual(try store.resolve(id: "cabc1").comment.id, "cabc12345")
        XCTAssertThrowsError(try store.resolve(id: "cabc"), "ambiguous prefix")
        XCTAssertThrowsError(try store.resolve(id: "cab"), "prefixes shorter than 4 never match")

        let before = ReviewAttachmentPaths.before(a.id)
        try project.ensureDotDir()
        try Data([1]).write(to: store.url(forAttachment: before))
        try store.attach(scene: "Hello", id: a.id, ReviewAttachment(kind: .before, path: before, t: 1))
        try store.attach(scene: "Hello", id: a.id, ReviewAttachment(kind: .before, path: before, t: 1.5))
        let reply = ReviewReply(author: .agent(), body: "done")
        let after = ReviewAttachmentPaths.after(a.id, reply: reply.id)
        try Data([2]).write(to: store.url(forAttachment: after))
        var withAfter = reply
        withAfter.attachments = [ReviewAttachment(kind: .after, path: after, t: 1)]
        try store.reply(scene: "Hello", id: a.id, withAfter)

        let c = try store.resolve(id: a.id).comment
        XCTAssertEqual(c.attachments?.count, 1, "one before-frame per comment")
        XCTAssertEqual(c.beforeAttachment?.t, 1.5)
        XCTAssertEqual(c.latestAfter?.path, after)
        XCTAssertTrue(c.summaryLine.hasPrefix("cabc12345  00:01.00  open  a"))

        try store.remove(scene: "Hello", id: a.id)
        XCTAssertNil(store.find(id: a.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(forAttachment: before).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(forAttachment: after).path))
    }

    func testReviewImageDrawsBoxOutsideRegionAndScales() throws {
        let w = 400, h = 200
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let black = try XCTUnwrap(ctx.makeImage())

        // Region: x 100…300, y 50…150 (top-left origin).
        let boxed = ReviewImage.annotated(black, region: ReviewRegion(x: 0.25, y: 0.25, w: 0.5, h: 0.5))
        let png = try ReviewImage.png(boxed)
        let decoded = try ReviewImage.load(data: png)
        XCTAssertEqual(decoded.width, w)
        let pixel = try pixels(decoded)
        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {   // y from the top
            let i = (y * w + x) * 4
            return (Int(pixel[i]), Int(pixel[i + 1]), Int(pixel[i + 2]))
        }
        let edge = rgb(200, 48)                        // just above the region's top edge
        XCTAssertGreaterThan(edge.0, 200, "stroke is pink-red: \(edge)")
        XCTAssertLessThan(edge.1, 120)
        XCTAssertEqual(rgb(200, 100).0, 0, "inside the region stays untouched")
        XCTAssertEqual(rgb(200, 53).0, 0, "the stroke sits outside the region")
        XCTAssertEqual(rgb(20, 20).0, 0)

        let small = ReviewImage.scaled(boxed, maxWidth: 100)
        XCTAssertEqual([small.width, small.height], [100, 50])
        XCTAssertEqual(ReviewImage.scaled(boxed, maxWidth: 4000).width, w, "never upscales")
        XCTAssertTrue(ReviewImage.annotated(black, region: nil) === black)
    }

    private func pixels(_ img: CGImage) throws -> [UInt8] {
        var px = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let c = CGContext(data: buf.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8,
                                    bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            return true
        }
        XCTAssertTrue(ok)
        return px
    }

    // MARK: swift-render review (in-process renders)

    @MainActor
    func testReviewCommandRoundTripRendersFrames() throws {
        let project = try tempProject()
        let saved = sceneRunners
        sceneRunners = ["TimelineDemo": SceneRunner(TimelineDemo.self)]
        defer { sceneRunners = saved }
        let store = ReviewStore(project: project)

        let added = try reviewCommand(["add", "TimelineDemo", "--at", "1.2", "--region", "0.08,0.3,0.5,0.4",
                                       "--author", "Tester", "title", "lands", "late"], project: project)
        XCTAssertTrue(added.hasPrefix("added c"), added)
        let entry = try XCTUnwrap(store.all().first)
        XCTAssertEqual(entry.scene, "TimelineDemo")
        let c = entry.comment
        XCTAssertEqual(c.body, "title lands late")
        XCTAssertEqual(c.author, ReviewAuthor(name: "Tester"))
        XCTAssertEqual(c.canvas, ReviewCanvas(width: 1920, height: 1080, fps: 60))
        let before = try XCTUnwrap(c.beforeAttachment)
        XCTAssertEqual(try ReviewImage.load(store.url(forAttachment: before.path)).width, 1920)

        XCTAssertThrowsError(try reviewCommand(["add", "TimelineDemo", "--at", "42", "x"], project: project))
        XCTAssertThrowsError(try reviewCommand(["add", "Nope", "--at", "1", "x"], project: project))
        XCTAssertThrowsError(try reviewCommand(["add", "TimelineDemo", "--at", "1", "--region", "1,2", "x"], project: project))

        _ = try reviewCommand(["status", String(c.id.prefix(6)), "in-progress", "--agent"], project: project)
        XCTAssertEqual(try store.resolve(id: c.id).comment.assignee, .agent())
        let replied = try reviewCommand(["reply", c.id, "--agent", "--attach-frame", "--", "-moved", "the", "title"],
                                        project: project)
        XCTAssertTrue(replied.contains("after →"), replied)
        _ = try reviewCommand(["status", c.id, "resolved", "--resolution", "earlier title", "--agent"], project: project)

        let list = try reviewCommand(["list", "--status", "all", "--json"], project: project)
        let entries = try ReviewStore.decoder.decode([ReviewEntry].self, from: Data(list.utf8))
        let done = try XCTUnwrap(entries.first?.comment)
        XCTAssertEqual(done.status, .resolved)
        XCTAssertNil(done.assignee)
        XCTAssertEqual(done.resolution, "earlier title")
        XCTAssertEqual(done.replies.first?.body, "-moved the title")
        XCTAssertEqual(done.replies.first?.author.kind, .agent)
        let after = try XCTUnwrap(done.latestAfter)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(forAttachment: after.path).path))
        XCTAssertEqual(try reviewCommand(["list"], project: project), "no comments (open,inProgress)\n")

        let out = project.root.appendingPathComponent("boxed.png")
        _ = try reviewCommand(["frame", c.id, "--out", out.path, "--max-width", "480"], project: project)
        XCTAssertEqual(try ReviewImage.load(out).width, 480)
        XCTAssertTrue(try reviewCommand(["show", c.id], project: project).contains("resolution: earlier title"))

        _ = try reviewCommand(["delete", c.id], project: project)
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(forAttachment: before.path).path))
    }

    // MARK: swift-render-mcp over stdio

    func testMCPServerSpeaksJSONRPCOverStdio() throws {
        let bin = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("swift-render-mcp")
        guard FileManager.default.isExecutableFile(atPath: bin.path) else {
            throw XCTSkip("swift-render-mcp not built next to the test bundle (\(bin.path))")
        }
        let project = try tempProject()
        let store = ReviewStore(project: project)
        let c = try store.add(scene: "Hello", ReviewComment(t: 2.5, region: ReviewRegion(x: 0.1, y: 0.1, w: 0.2, h: 0.2),
                                                            body: "logo too small", author: ReviewAuthor(name: "Sky")))
        try store.setStatus(scene: "Hello", id: c.id, .inProgress, by: .agent())

        let lines: [String] = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"},"extra":1}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2030-01-01"}}"#,
            #"{"jsonrpc":"2.0","id":"p","method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_comments","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"reply_comment","arguments":{"id":"\#(c.id)","body":"which logo?","reopen":true}}}"#,
            #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"get_comment","arguments":{"id":"nope1234"}}}"#,
            #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"no_such_tool"}}"#,
            #"{"jsonrpc":"2.0","id":8,"method":"prompts/list"}"#,
            #"not json"#,
        ]
        let p = Process()
        p.executableURL = bin
        p.environment = ProcessInfo.processInfo.environment.merging(["SWIFT_RENDER_ROOT": project.root.path]) { $1 }
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        try p.run()
        input.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)

        // stdout is protocol only: every line is a JSON-RPC response; notifications get none.
        let replies = try String(decoding: data, as: UTF8.self).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertEqual(replies.count, lines.count - 1)
        XCTAssertTrue(replies.allSatisfy { $0["jsonrpc"] as? String == "2.0" })
        func result(_ i: Int) -> [String: Any] { replies[i]["result"] as? [String: Any] ?? [:] }
        func errorCode(_ i: Int) -> Int? { (replies[i]["error"] as? [String: Any])?["code"] as? Int }
        func text(_ i: Int) -> String {
            ((result(i)["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        }

        XCTAssertEqual(result(0)["protocolVersion"] as? String, "2025-03-26")
        XCTAssertNotNil((result(0)["capabilities"] as? [String: Any])?["tools"])
        XCTAssertEqual((result(0)["serverInfo"] as? [String: Any])?["name"] as? String, "swift-render")
        XCTAssertEqual(result(1)["protocolVersion"] as? String, "2025-11-25")
        XCTAssertEqual(replies[2]["id"] as? String, "p")
        let names = ((result(3)["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        // The review-loop contract; the creation tools (MCPCreateTests) come on top.
        XCTAssertTrue(Set(names).isSuperset(of: Self.toolNames), "\(names)")
        XCTAssertTrue(text(4).contains(c.id) && text(4).contains("logo too small"), text(4))
        XCTAssertEqual(result(5)["isError"] as? Bool, false, text(5))
        XCTAssertEqual(result(6)["isError"] as? Bool, true)
        XCTAssertEqual(errorCode(7), -32602)
        XCTAssertEqual(errorCode(8), -32601)
        XCTAssertEqual(errorCode(9), -32700)

        let thread = try store.resolve(id: c.id).comment
        XCTAssertEqual(thread.replies.last?.body, "which logo?")
        XCTAssertEqual(thread.replies.last?.author.kind, .agent)
        XCTAssertEqual(thread.status, .open, "reopen gives the claim back")
        XCTAssertNil(thread.assignee)
    }

    // MARK: agent, skill, plugin

    func testAgentSkillAndPluginStayInSync() throws {
        func read(_ path: String) throws -> String {
            try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
        }
        func split(_ md: String) -> (frontmatter: String, body: String) {
            let parts = md.components(separatedBy: "---\n")
            return (parts.count > 2 ? parts[1] : "", parts.dropFirst(2).joined(separator: "---\n"))
        }
        let agent = split(try read(".claude/agents/swift-render-director.md"))
        let pluginAgent = split(try read("claude-plugin/agents/swift-render-director.md"))
        XCTAssertEqual(agent.body, pluginAgent.body, "plugin agent body must match .claude/agents")
        XCTAssertEqual(agent.frontmatter.replacingOccurrences(of: "mcp__swift-render__", with: "mcp__plugin_swift-render_swift-render__"),
                       pluginAgent.frontmatter, "plugin agent differs only in MCP tool prefixes")
        XCTAssertTrue(agent.frontmatter.contains("name: swift-render-director\n"))
        for tool in Self.toolNames {
            XCTAssertTrue(agent.frontmatter.contains("mcp__swift-render__\(tool)"), "director can call \(tool)")
        }
        XCTAssertEqual(try read(".claude/skills/swift-render-review/SKILL.md"),
                       try read("claude-plugin/skills/swift-render-review/SKILL.md"))

        func json(_ path: String) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try read(path).utf8)) as? [String: Any], path)
        }
        let plugin = try json("claude-plugin/.claude-plugin/plugin.json")
        let market = try json(".claude-plugin/marketplace.json")
        let listed = try XCTUnwrap((market["plugins"] as? [[String: Any]])?.first)
        XCTAssertEqual(plugin["name"] as? String, listed["name"] as? String)
        XCTAssertEqual(listed["source"] as? String, "./claude-plugin")
        XCTAssertEqual(plugin["version"] as? String, swiftRenderVersion)
        XCTAssertEqual(listed["version"] as? String, swiftRenderVersion)
        for path in [".mcp.json", "claude-plugin/.mcp.json"] {
            XCTAssertNotNil((try json(path)["mcpServers"] as? [String: Any])?["swift-render"], "\(path) registers swift-render")
        }
    }
}
