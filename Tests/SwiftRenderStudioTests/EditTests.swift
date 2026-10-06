import AppKit
import SwiftUI
import XCTest
import SwiftRenderKit
@testable import SwiftRenderStudio

/// Right-click menus, deletes and Undo: the ReviewStore round trip (comment + attachment
/// files), reply deletion, Trash confinement, scene duplication, the ⌫ key and the menu model.
@MainActor
final class EditTests: XCTestCase {
    private var root: URL!
    private var fakeTrash: URL!

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sr-edit-\(UUID().uuidString)")
        root = base.appendingPathComponent("proj")
        fakeTrash = base.appendingPathComponent("Trash")
        for d in [".swift-render/reviews", ".swift-render/attachments", "Sources/Demo", "out", ".build/x"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        try "// swift-tools-version: 5.10".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private var store: ReviewStore { ReviewStore(project: Project(root: root)) }

    /// Moves into a temp folder instead of the real Trash.
    private func trash() -> ProjectTrash {
        let bin = fakeTrash!
        return ProjectTrash(root: root) { url in
            let dest = bin.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        }
    }

    private func write(_ text: String, _ rel: String) throws -> URL {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A comment with a `.before` frame and a reply carrying an `.after` frame.
    private func seedComment() throws -> ReviewComment {
        var c = ReviewComment(t: 2, end: nil, region: nil, body: "Too fast", author: ReviewAuthor(name: "Sky"))
        let before = ReviewAttachmentPaths.before(c.id)
        try Data([1, 2, 3]).write(to: root.appendingPathComponent(before))
        c.attachments = [ReviewAttachment(kind: .before, path: before, t: 2)]
        var reply = ReviewReply(author: .agent(), body: "Slowed it")
        let after = ReviewAttachmentPaths.after(c.id, reply: reply.id)
        try Data([4, 5]).write(to: root.appendingPathComponent(after))
        reply.attachments = [ReviewAttachment(kind: .after, path: after, t: 2)]
        c.replies = [ReviewReply(author: ReviewAuthor(name: "Sky"), body: "Please look"), reply]
        try store.add(scene: "Demo", c)
        return try XCTUnwrap(store.load(scene: "Demo").comments.first)     // as stored (dates to the second)
    }

    // MARK: ReviewStore round trip

    func testDeleteKeepsACopyThatRestoresTheCommentAndItsFiles() throws {
        let c = try seedComment()
        let files = ReviewController.attachments(of: c).map { root.appendingPathComponent($0.path) }
        let d = try store.removeKeepingCopy(scene: "Demo", id: c.id)
        XCTAssertTrue(try store.load(scene: "Demo").comments.isEmpty)
        XCTAssertFalse(files.contains { FileManager.default.fileExists(atPath: $0.path) }, "remove() deletes attachments")
        XCTAssertEqual(d.files.count, 2)

        try store.restore(d)
        XCTAssertEqual(try store.load(scene: "Demo").comments, [c])
        XCTAssertEqual(try Data(contentsOf: files[0]), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: files[1]), Data([4, 5]))
        // Restoring twice never duplicates.
        try store.restore(d)
        XCTAssertEqual(try store.load(scene: "Demo").comments.count, 1)
    }

    func testCraftedAttachmentPathsAreNeitherReadNorWritten() throws {
        let outside = root.deletingLastPathComponent().appendingPathComponent("secret.txt")
        try "keep".write(to: outside, atomically: true, encoding: .utf8)
        var c = ReviewComment(t: 0, end: nil, region: nil, body: "x", author: ReviewAuthor(name: "Sky"))
        c.attachments = [ReviewAttachment(kind: .before, path: ".swift-render/attachments/../../../secret.txt", t: 0)]
        try store.add(scene: "Demo", c)
        let d = try store.removeKeepingCopy(scene: "Demo", id: c.id)
        XCTAssertTrue(d.files.isEmpty)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "keep")
        // A forged copy can't write outside either.
        var forged = d
        forged.files = [".swift-render/attachments/../../../secret.txt": Data("pwned".utf8), "/tmp/x": Data()]
        try store.restore(forged)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "keep")
    }

    func testReplyDeleteRemovesOnlyItsFilesAndRestoresInPlace() throws {
        let c = try seedComment()
        let reply = c.replies[1]
        let r = try store.removeReply(scene: "Demo", commentID: c.id, replyID: reply.id)
        XCTAssertEqual(r.index, 1)
        let after = root.appendingPathComponent(reply.attachments[0].path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: after.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(c.attachments![0].path).path),
                      "the comment's own frame stays")
        XCTAssertEqual(try store.load(scene: "Demo").comments[0].replies.map(\.id), [c.replies[0].id])
        try store.restore(r)
        XCTAssertEqual(try store.load(scene: "Demo").comments[0].replies.map(\.id), c.replies.map(\.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: after.path))
        XCTAssertTrue(ReviewController.canDelete(c.replies[0]))
        XCTAssertFalse(ReviewController.canDelete(reply), "Claude's replies aren't deletable from Studio")
    }

    // MARK: Undo through the window's UndoManager

    func testDeleteCommentUndoRedo() throws {
        let c = try seedComment()
        let model = ProjectModel(root: root, options: LaunchOptions(fakeHost: true))
        model.review.load(scene: "Demo")
        let um = UndoManager()
        um.groupsByEvent = false
        model.edits.undoManager = um

        model.review.selection = c.id
        model.perform(.deleteSelection)
        XCTAssertEqual(model.edits.pending, .deleteComment(id: c.id), "⌫ asks first")
        XCTAssertEqual(model.edits.confirmation(for: model.edits.pending!).button, "Delete Comment")
        XCTAssertEqual(model.review.comments.count, 1, "nothing is deleted before confirming")

        um.beginUndoGrouping(); model.edits.confirm(); um.endUndoGrouping()
        XCTAssertTrue(model.review.comments.isEmpty)
        XCTAssertEqual(um.undoActionName, "Delete Comment")

        um.undo()
        XCTAssertEqual(model.review.comments, [c])
        XCTAssertEqual(model.review.selection, c.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(c.attachments![0].path).path))

        um.redo()
        XCTAssertTrue(model.review.comments.isEmpty)
        um.undo()
        XCTAssertEqual(model.review.comments.count, 1)

        // Redo after switching scenes deletes from the comment's own scene, not the open one.
        model.review.load(scene: "Other")
        um.redo()
        XCTAssertTrue(try store.load(scene: "Demo").comments.isEmpty, "redo reached Demo")
        um.undo()
        XCTAssertEqual(try store.load(scene: "Demo").comments.count, 1)
    }

    func testTrashExportUndoPutsItBack() throws {
        let file = try write("mp4", "out/Demo-preview.mp4")
        let model = ProjectModel(root: root, options: LaunchOptions(fakeHost: true))
        model.edits.trash = trash()
        let um = UndoManager()
        um.groupsByEvent = false
        model.edits.undoManager = um
        model.edits.request(.trashExport(file))
        um.beginUndoGrouping(); model.edits.confirm(); um.endUndoGrouping()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fakeTrash.path).count, 1)
        um.undo()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "mp4")
    }

    /// Edit › Delete / Copy from a SwiftUI window with nothing focused reach `EditResponder`.
    func testEditMenuReachesTheResponderAfterTheWindow() throws {
        let c = try seedComment()
        let model = ProjectModel(root: root, options: LaunchOptions(fakeHost: true))
        model.review.load(scene: "Demo")
        model.review.selection = c.id
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Text("Studio"))
        window.contentView = host
        EditResponder.install(model: model, in: window)
        EditResponder.install(model: model, in: window)
        let responder = try XCTUnwrap(window.nextResponder as? EditResponder)
        XCTAssertFalse(responder.nextResponder is EditResponder, "installed once")

        XCTAssertTrue(host.tryToPerform(#selector(NSText.delete(_:)), with: nil))
        XCTAssertEqual(model.edits.pending, .deleteComment(id: c.id), "asks; nothing deleted yet")
        XCTAssertEqual(model.review.comments.count, 1)

        let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        XCTAssertTrue(responder.validateMenuItem(copy))
        model.review.selection = nil
        XCTAssertFalse(responder.validateMenuItem(copy), "Copy is dimmed with no comment selected")
    }

    // MARK: Trash confinement

    func testTrashOnlyTakesPlainFilesInsideTheProject() throws {
        let t = trash()
        let scene = try write("x", "Sources/Demo/Hero.swift")
        let outside = try { () throws -> URL in
            let u = root.deletingLastPathComponent().appendingPathComponent("Outside.swift")
            try "o".write(to: u, atomically: true, encoding: .utf8); return u
        }()
        func refused(_ url: URL, within: URL? = nil, ext: Set<String>? = nil) -> ProjectFileError? {
            do { _ = try t.validate(url, within: within, extensions: ext); return nil } catch { return error as? ProjectFileError }
        }
        XCTAssertNoThrow(try t.validate(scene, within: root.appendingPathComponent("Sources"), extensions: ["swift"]))
        XCTAssertEqual(refused(outside), .outsideProject("Outside.swift"))
        XCTAssertEqual(refused(root.appendingPathComponent("Sources/../../Outside.swift")), .outsideProject("Outside.swift"))
        XCTAssertNotNil(refused(root), "the project itself")
        XCTAssertNotNil(refused(root.appendingPathComponent("Sources")), "a folder")
        XCTAssertEqual(refused(try write("b", ".build/x/a.swift")), .hidden("a.swift"))
        XCTAssertEqual(refused(root.appendingPathComponent("Package.swift"), within: root.appendingPathComponent("out")),
                       .wrongKind("Package.swift"))
        XCTAssertEqual(refused(try write("t", "Sources/Demo/notes.txt"), ext: ["swift"]), .wrongKind("notes.txt"))
        XCTAssertEqual(refused(root.appendingPathComponent("Sources/Demo/Gone.swift")), .missing("Gone.swift"))

        // A symlinked folder that leads out of the project.
        let link = root.appendingPathComponent("Sources/Escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.deletingLastPathComponent())
        XCTAssertEqual(refused(link.appendingPathComponent("Outside.swift")), .outsideProject("Outside.swift"))
        // A symlinked file is never followed.
        let fileLink = root.appendingPathComponent("Sources/Demo/Link.swift")
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: outside)
        XCTAssertEqual(refused(fileLink), .notAFile("Link.swift"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))

        // Trash + put back; never over a file that took its place.
        let moved = try t.trash(scene)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scene.path))
        _ = try write("new", "Sources/Demo/Hero.swift")
        XCTAssertThrowsError(try t.restore(moved)) { XCTAssertEqual($0 as? ProjectFileError, .occupied("Hero.swift")) }
        try FileManager.default.removeItem(at: scene)
        try t.restore(moved)
        XCTAssertEqual(try String(contentsOf: scene, encoding: .utf8), "x")
        XCTAssertThrowsError(try t.restore(TrashedFile(original: scene, trashed: nil)))
    }

    // MARK: Scenes

    func testFindsAndDuplicatesASceneOnlyWhenTheCopyCantClash() throws {
        let simple = """
        import SwiftUI
        import SwiftRender

        /// Hero scene.
        @MainActor
        public struct Hero: RenderScene {
            public init() {}
            public var body: some View { Text("Hero") }
        }

        extension Hero {
            static let name = "Hero"
        }

        private struct Badge: View { var body: some View { EmptyView() } }
        """
        let file = try write(simple, "Sources/Demo/Hero.swift")
        XCTAssertEqual(SceneFiles.scenesDeclared(in: simple), ["Hero"])
        XCTAssertEqual(SceneFiles.scan(scene: "Hero", root: root)?.lastPathComponent, file.lastPathComponent)
        XCTAssertNil(SceneFiles.sharedDeclaration(in: simple, scene: "Hero"))
        let copy = try SceneFiles.duplicateSource(simple, scene: "Hero", as: "HeroCopy")
        XCTAssertTrue(copy.contains("public struct HeroCopy: RenderScene"))
        XCTAssertTrue(copy.contains("extension HeroCopy {"))
        XCTAssertTrue(copy.contains("private struct Badge"))
        XCTAssertEqual(SceneFiles.copyName(for: "Hero", taken: ["HeroCopy"], folder: file.deletingLastPathComponent(), source: simple),
                       "HeroCopy2")

        let shared = simple + "\nstruct Card: View { var body: some View { EmptyView() } }\n"
        XCTAssertEqual(SceneFiles.sharedDeclaration(in: shared, scene: "Hero"), "struct Card")
        XCTAssertThrowsError(try SceneFiles.duplicateSource(shared, scene: "Hero", as: "HeroCopy"))
        XCTAssertEqual(SceneFiles.sharedDeclaration(in: simple + "\nextension Color { static let x = 1 }\n", scene: "Hero"),
                       "extension Color")
    }

    // MARK: Keys and menus

    func testDeleteKeyDeletesTheSelectionButNeverWhileTyping() {
        let r = KeyRouter(model: nil)
        XCTAssertEqual(r.action(for: .init(chars: "\u{7f}", keyCode: 51), textEditing: false), .deleteSelection)
        XCTAssertEqual(r.action(for: .init(chars: "", keyCode: 117), textEditing: false), .deleteSelection)
        XCTAssertNil(r.action(for: .init(chars: "\u{7f}", keyCode: 51), textEditing: true))
        XCTAssertNil(r.action(for: .init(chars: "\u{7f}", keyCode: 51, command: true), textEditing: false), "⌘⌫ is the menu's")
    }

    func testCommentMenuFollowsTheMacOrderForEachState() throws {
        let c = try seedComment()
        let model = ProjectModel(root: root, options: LaunchOptions(fakeHost: true))
        model.review.load(scene: "Demo")
        let open = ContextMenus.comment(c, model: model).outline
        XCTAssertEqual(open, ["Reply", "Jump to 0:02.00", "Compare Before and After", "—",
                              "Mark Done", "Won't Fix", "Ask Claude…", "—",
                              "Copy Text ⌘C", "Copy Reference", "—", "Delete Comment… ⌫"])
        var done = c
        done.status = .resolved
        done.acceptedBy = ReviewAuthor(name: "Sky")
        XCTAssertTrue(ContextMenus.comment(done, model: model).outline.contains("Reopen"))
        XCTAssertFalse(ContextMenus.comment(done, model: model).outline.contains("Mark Done"))

        // Copy Reference names the scene, time and id.
        XCTAssertEqual(model.edits.reference(c), "Demo @ 0:02.00 (\(c.id))")

        // Delete asks first; Reply opens the thread with the reply field focused.
        ContextMenus.comment(c, model: model).item("Delete Comment…")?.action()
        XCTAssertEqual(model.edits.pending, .deleteComment(id: c.id))
        ContextMenus.comment(c, model: model).item("Reply")?.action()
        XCTAssertEqual(model.edits.replyFocus, c.id)
        XCTAssertTrue(model.review.threadOpen)

        XCTAssertEqual(ContextMenus.reply(c.replies[0], in: c, model: model).outline, ["Copy", "—", "Delete Reply…"])
        XCTAssertEqual(ContextMenus.reply(c.replies[1], in: c, model: model).outline, ["Copy"])
    }

    func testOtherMenus() throws {
        let model = ProjectModel(root: root, options: LaunchOptions(fakeHost: true))
        let scene = SceneSummary(name: "Hero", kind: .render, defaultDuration: 5, hasSoundtrack: false, hasProps: false)
        XCTAssertEqual(ContextMenus.scene(scene, model: model).outline.filter { $0 != "—" }.map { $0.hasPrefix("Open in") ? "Open in" : $0 },
                       ["Open", "Open in", "Show in Finder", "Copy Name", "Duplicate", "Move to Trash…"])
        let inOut = root.appendingPathComponent("out/a.mp4")
        try FileManager.default.createDirectory(at: inOut.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("mp4".utf8).write(to: inOut)
        XCTAssertEqual(ContextMenus.export(inOut, model: model).outline,
                       ["Open", "Show in Finder", "—", "Copy Path", "—", "Move to Trash…"])
        // An export saved outside out/ is the person's to manage: no Move to Trash.
        let elsewhere = root.appendingPathComponent("b.mp4")
        try Data("mp4".utf8).write(to: elsewhere)
        XCTAssertEqual(ContextMenus.export(elsewhere, model: model).outline, ["Open", "Show in Finder", "—", "Copy Path"])
        // A host menu that adds its own commands keeps the destructive group last.
        let c = ReviewComment(id: "c1", t: 1, body: "x", author: ReviewAuthor(name: "Sky"))
        let split = ContextMenus.comment(c, model: model).splitDestructive
        XCTAssertEqual(split.destructive.compactMap(\.item?.title), ["Delete Comment…"])
        XCTAssertFalse(split.head.contains { $0.item?.destructive == true })
        if case .divider = split.head.last { XCTFail("trailing separator left in the head") }
        XCTAssertEqual(ContextMenus.time(1, model: model).outline, ["Add Comment Here", "—", "Set In Here", "Set Out Here"])
        let frame = ContextMenus.frame(at: CGPoint(x: 0.5, y: 0.5), model: model)
        XCTAssertEqual(frame.outline, ["Add Comment Here", "—", "Copy Frame (off)", "Save Frame As… (off)", "—",
                                       "Fit", "Actual Size", "—", "Show Safe Areas"])
        XCTAssertEqual(frame.item("Fit")?.checked, true)
        // The builder never doubles or trails separators.
        var b = StudioMenuBuilder()
        b.divider(); b.add("A") {}; b.divider(); b.divider(); b.add("B") {}; b.divider()
        XCTAssertEqual(b.built.outline, ["A", "—", "B"])
        XCTAssertEqual(ViewerContextMenu.normalized(CGPoint(x: 60, y: 30), in: CGRect(x: 10, y: 10, width: 100, height: 40)),
                       CGPoint(x: 0.5, y: 0.5))
        XCTAssertNil(ViewerContextMenu.normalized(CGPoint(x: 0, y: 0), in: CGRect(x: 10, y: 10, width: 100, height: 40)))
    }
}
