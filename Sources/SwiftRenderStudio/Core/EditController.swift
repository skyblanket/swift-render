import AppKit
import Foundation
import Observation
import SwiftRenderKit

// MARK: - Edit controller
//
// The destructive and clipboard commands behind every right-click menu, ⌫ and Edit ›
// Copy / Undo. Data safety rules, in order:
//
//   1. Ask first. A delete sets `pending`; the project window shows one confirmation
//      dialog (destructive button, Cancel by default) naming exactly what goes.
//   2. Files go to the Trash, never `rm`, and only files `ProjectTrash` confines to the
//      project (no `..`, no symlinked way out, no hidden folders).
//   3. Everything is undoable through the window's UndoManager (Edit › Undo, ⌘Z): a deleted
//      comment or reply is re-added with its attachment files; a trashed file is moved
//      back. When that can't work the dialog says where the file is instead.

/// A destructive edit waiting for the person to confirm it.
enum PendingEdit: Equatable, Identifiable {
    case deleteComment(id: String)
    case deleteReply(commentID: String, replyID: String)
    /// `others`: other scenes declared in the same file (they go too).
    case trashScene(name: String, file: URL, others: [String])
    case trashExport(URL)

    var id: String {
        switch self {
        case .deleteComment(let id): return "comment:\(id)"
        case .deleteReply(let c, let r): return "reply:\(c)/\(r)"
        case .trashScene(let n, _, _): return "scene:\(n)"
        case .trashExport(let u): return "export:\(u.path)"
        }
    }
}

/// What the confirmation dialog says.
struct ConfirmationText: Equatable {
    var title: String
    var message: String
    var button: String
}

@MainActor @Observable
final class EditController {
    @ObservationIgnored private unowned let model: ProjectModel
    /// The edit the confirmation dialog is asking about.
    var pending: PendingEdit?
    /// A comment whose thread should open with the reply field focused (Reply in a menu).
    var replyFocus: String?
    /// The window's undo manager (Edit › Undo / Redo); set by the project window.
    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored var trash: ProjectTrash

    init(model: ProjectModel) {
        self.model = model
        self.trash = ProjectTrash(root: model.project.root)
    }

    // MARK: Asking first

    func request(_ edit: PendingEdit) { pending = edit }

    /// The dialog's words for `edit` (pure enough to test and to snapshot).
    func confirmation(for edit: PendingEdit) -> ConfirmationText {
        switch edit {
        case .deleteComment(let id):
            let c = model.review.comments.first { $0.id == id }
            let n = model.review.number(of: id).map { " #\($0)" } ?? ""
            var parts: [String] = []
            if let c {
                let first = c.body.split(separator: "\n").first.map(String.init) ?? c.body
                let quote = first.count > 60 ? String(first.prefix(59)) + "…" : first
                let replies = c.replies.filter { !ReviewStyle.isStudioNote($0.author) }.count
                parts.append("“\(quote)”" + (replies > 0 ? " and its \(ReviewStyle.replies(replies)) will be removed." : " will be removed."))
                if c.beforeAttachment != nil || c.latestAfter != nil { parts.append("Its saved frames go too.") }
            }
            parts.append("You can undo this with Edit › Undo (⌘Z).")
            return ConfirmationText(title: "Delete comment\(n)?", message: parts.joined(separator: " "), button: "Delete Comment")
        case .deleteReply:
            return ConfirmationText(title: "Delete this reply?",
                                    message: "It's removed from the thread. You can undo this with Edit › Undo (⌘Z).",
                                    button: "Delete Reply")
        case .trashScene(let name, let file, let others):
            var msg = "\(name) disappears from Studio after the next build."
            if !others.isEmpty {
                msg += " This file also holds \(TranscriptText.list(others)), so \(others.count == 1 ? "it goes" : "they go") too."
            }
            msg += " Comments and saved knobs stay in .swift-render. You can undo with Edit › Undo (⌘Z), or put the file back from the Trash."
            return ConfirmationText(title: "Move “\(file.lastPathComponent)” to the Trash?", message: msg, button: "Move to Trash")
        case .trashExport(let url):
            return ConfirmationText(title: "Move “\(url.lastPathComponent)” to the Trash?",
                                    message: "You can undo with Edit › Undo (⌘Z), or put it back from the Trash.",
                                    button: "Move to Trash")
        }
    }

    /// The person confirmed: do it.
    func confirm() {
        guard let edit = pending else { return }
        pending = nil
        switch edit {
        case .deleteComment(let id): deleteComment(id)
        case .deleteReply(let c, let r): deleteReply(c, replyID: r)
        case .trashScene(let name, let file, _): trashScene(name, file: file)
        case .trashExport(let url): trashExport(url)
        }
    }

    // MARK: Comments

    /// ⌫ / Edit › Delete: the selected comment, after asking.
    func deleteSelection() {
        guard let id = model.review.selection, model.review.comments.contains(where: { $0.id == id }) else { return }
        request(.deleteComment(id: id))
    }

    func deleteComment(_ id: String) {
        do {
            let d = try model.review.deleteKeepingCopy(id)
            registerUndo("Delete Comment") { $0.restoreComment(d) }
        } catch {
            model.ui.toast = "Couldn't delete the comment. \(error)"
        }
    }

    private func restoreComment(_ d: DeletedComment) {
        do {
            try model.review.restore(d)
            registerUndo("Delete Comment") { $0.deleteComment(d.comment.id) }
        } catch {
            model.ui.toast = "Couldn't bring the comment back. \(error)"
        }
    }

    func deleteReply(_ commentID: String, replyID: String) {
        do {
            let r = try model.review.deleteReply(commentID, replyID: replyID)
            registerUndo("Delete Reply") { $0.restoreReply(r) }
        } catch {
            model.ui.toast = "Couldn't delete the reply. \(error)"
        }
    }

    private func restoreReply(_ r: DeletedReply) {
        do {
            try model.review.restore(r)
            registerUndo("Delete Reply") { $0.deleteReply(r.commentID, replyID: r.reply.id) }
        } catch {
            model.ui.toast = "Couldn't bring the reply back. \(error)"
        }
    }

    /// "AppleLaunch @ 0:06.20 (c49807dc8)": scene, time and id, enough for a person to find
    /// it and for `swift-render review show <id>` / the MCP tools.
    func reference(_ c: ReviewComment) -> String {
        let scene = model.review.scene ?? model.selectedScene ?? ""
        let time = c.end.map { "\(StudioTime.precise(c.t))–\(StudioTime.precise($0))" } ?? StudioTime.precise(c.t)
        return "\(scene) @ \(time) (\(c.id))"
    }

    /// Opens the comment's thread with the reply field focused.
    func reply(to id: String) {
        model.review.open(id)
        model.ui.inspectorTab = .comments
        model.ui.showInspector = true
        replyFocus = id
    }

    // MARK: Scenes

    /// The file that declares `scene`, or nil (older host, scene outside `Sources/`).
    func sceneFile(_ scene: String) -> URL? {
        let reported = model.scenes.first { $0.name == scene }?.sourcePath
            ?? (model.info?.name == scene ? model.info?.sourcePath : nil)
        return SceneFiles.locate(scene: scene, reported: reported, root: model.project.root)
    }

    func openScene(_ scene: String) { Task { await model.select(scene: scene) } }

    func openSceneInEditor(_ scene: String) {
        guard let url = sceneFile(scene) else { model.ui.toast = "Studio can't find \(scene)'s Swift file"; return }
        SourceOpener.open(file: url.path, line: 1)
    }

    func revealScene(_ scene: String) {
        guard let url = sceneFile(scene) else { model.ui.toast = "Studio can't find \(scene)'s Swift file"; return }
        SourceOpener.reveal(url)
    }

    /// Move to Trash…: checks the file first so the dialog only ever names a file Studio may move.
    func requestTrashScene(_ scene: String) {
        guard let url = sceneFile(scene) else { model.ui.toast = "Studio can't find \(scene)'s Swift file"; return }
        do {
            let file = try trash.validate(url, within: model.project.root.appendingPathComponent("Sources"), extensions: ["swift"])
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let others = SceneFiles.scenesDeclared(in: text).filter { $0 != scene }
            request(.trashScene(name: scene, file: file, others: others))
        } catch {
            model.ui.toast = "Studio won't move that file: \(error)"
        }
    }

    func trashScene(_ scene: String, file: URL) {
        do {
            // Step off the scene first so the viewer isn't left on a scene that's going away.
            if model.selectedScene == scene, let next = model.scenes.first(where: { $0.name != scene })?.name {
                Task { await model.select(scene: next) }
            }
            let t = try trash.trash(file, within: model.project.root.appendingPathComponent("Sources"), extensions: ["swift"])
            model.ui.toast = "Moved \(file.lastPathComponent) to the Trash. \(scene) goes away after the build."
            registerUndo("Move to Trash") { $0.putBack(t) }
        } catch {
            model.ui.toast = "Couldn't move \(file.lastPathComponent) to the Trash. \(error)"
        }
    }

    /// Duplicate: a copy of the scene's file with the type renamed, next to the original.
    /// Refused (with the reason) when the copy would clash with the original.
    func duplicateScene(_ scene: String) {
        guard let url = sceneFile(scene) else { model.ui.toast = "Studio can't find \(scene)'s Swift file"; return }
        do {
            let file = try trash.validate(url, within: model.project.root.appendingPathComponent("Sources"), extensions: ["swift"])
            let source = try String(contentsOf: file, encoding: .utf8)
            let folder = file.deletingLastPathComponent()
            let name = SceneFiles.copyName(for: scene, taken: Set(model.scenes.map(\.name)), folder: folder, source: source)
            let copy = try SceneFiles.duplicateSource(source, scene: scene, as: name)
            let dest = folder.appendingPathComponent(name + ".swift")
            guard !FileManager.default.fileExists(atPath: dest.path) else { throw ProjectFileError.occupied(dest.lastPathComponent) }
            try copy.write(to: dest, atomically: true, encoding: .utf8)
            model.ui.toast = "Made \(name) in \(dest.lastPathComponent). It shows up after the build."
            registerUndo("Duplicate Scene") { $0.trashCopy(dest) }
        } catch {
            model.ui.toast = "Couldn't duplicate \(scene). \(error)"
        }
    }

    /// Undo of Duplicate: the copy goes to the Trash (it's never deleted outright).
    private func trashCopy(_ url: URL) {
        do {
            let t = try trash.trash(url, within: model.project.root.appendingPathComponent("Sources"), extensions: ["swift"])
            registerUndo("Duplicate Scene") { $0.putBack(t) }
        } catch {
            model.ui.toast = "Couldn't remove the copy. \(error)"
        }
    }

    // MARK: Exports

    func trashExport(_ url: URL) {
        do {
            let t = try trash.trash(url, within: model.project.rendersDir)
            model.renders.outputsChanged()
            registerUndo("Move to Trash") { $0.putBack(t) }
        } catch {
            model.ui.toast = "Couldn't move \(url.lastPathComponent) to the Trash. \(error)"
        }
    }

    /// Undo of any Move to Trash.
    private func putBack(_ t: TrashedFile) {
        do {
            try trash.restore(t)
            model.renders.outputsChanged()
            model.ui.toast = "Put back \(t.original.lastPathComponent)"
            registerUndo("Move to Trash") { me in
                do {
                    let again = try me.trash.trash(t.original)
                    me.model.renders.outputsChanged()
                    me.registerUndo("Move to Trash") { $0.putBack(again) }
                } catch {
                    me.model.ui.toast = "Couldn't move \(t.original.lastPathComponent) to the Trash. \(error)"
                }
            }
        } catch {
            model.ui.toast = "Couldn't put \(t.original.lastPathComponent) back (\(error)). It's still in the Trash."
        }
    }

    // MARK: Clipboard and frames

    func copy(_ text: String) { Self.copyToPasteboard(text) }

    nonisolated static func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// The full-resolution frame at `t` as a PNG on the clipboard (rendered by the host).
    func copyFrame(at t: Double) {
        guard let capture = model.review.captureStill else { model.ui.toast = "Copy Frame needs the preview running"; return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("studio-frame-\(UUID().uuidString).png")
        Task {
            defer { try? FileManager.default.removeItem(at: tmp) }
            do {
                try await capture(t, tmp)
                let data = try Data(contentsOf: tmp)
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setData(data, forType: .png)
                if let tiff = NSImage(data: data)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
                model.ui.toast = "Copied the frame at \(StudioTime.precise(t))"
            } catch {
                model.ui.toast = "Couldn't copy the frame. \(error)"
            }
        }
    }

    /// Save Frame As…: a PNG wherever the person picks.
    func saveFrame(at t: Double) {
        guard let capture = model.review.captureStill else { model.ui.toast = "Save Frame needs the preview running"; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(model.selectedScene ?? "Frame")-\(StudioTime.precise(t).replacingOccurrences(of: ":", with: ".")).png"
        panel.directoryURL = model.project.rendersDir
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await capture(t, url)
                model.ui.toast = "Saved \(url.lastPathComponent)"
            } catch {
                model.ui.toast = "Couldn't save the frame. \(error)"
            }
        }
    }

    // MARK: Undo

    private func registerUndo(_ name: String, _ handler: @escaping @MainActor (EditController) -> Void) {
        guard let um = undoManager else { return }
        um.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { handler(target) }
        }
        um.setActionName(name)
    }
}
