import Foundation
import SwiftRenderKit

// MARK: - Deleting comments and replies, undoably
//
// A delete goes through `ReviewStore` (flock + atomic write) like every other review
// edit, and keeps an in-memory copy of what it removed — the comment or reply plus the
// bytes of the attachment files that went with it — so Edit › Undo can put both back.
// Only files `containedAttachmentURL` accepts are read or written: review files are
// shared through git, so their attachment paths are untrusted.

/// A comment removed by `removeKeepingCopy`, with everything needed to put it back.
struct DeletedComment: Equatable, Sendable {
    var scene: String
    var comment: ReviewComment
    /// Attachment files removed with it: project-relative path → contents.
    var files: [String: Data]
}

/// A reply removed by `removeReply`, with its place in the thread.
struct DeletedReply: Equatable, Sendable {
    var scene: String
    var commentID: String
    var index: Int
    var reply: ReviewReply
    var files: [String: Data]
}

extension ReviewStore {
    /// `remove(scene:id:)` — the comment and its attachment files — keeping a copy.
    func removeKeepingCopy(scene: String, id: String) throws -> DeletedComment {
        guard let comment = try load(scene: scene).comments.first(where: { $0.id == id }) else {
            throw ReviewError.notFound(scene: scene, id: id)
        }
        let files = readAttachments(ReviewController.attachments(of: comment))
        try remove(scene: scene, id: id)
        return DeletedComment(scene: scene, comment: comment, files: files)
    }

    /// Puts a deleted comment back: its files first (never over an existing file), then the
    /// comment itself, unless someone already re-added one with the same id.
    func restore(_ d: DeletedComment) throws {
        writeAttachments(d.files)
        try mutate(scene: d.scene) { file in
            if !file.comments.contains(where: { $0.id == d.comment.id }) { file.comments.append(d.comment) }
        }
    }

    /// Removes one reply (and attachment files only it used), keeping a copy.
    func removeReply(scene: String, commentID: String, replyID: String) throws -> DeletedReply {
        let removed: (index: Int, reply: ReviewReply, keep: Set<String>) = try mutate(scene: scene) { file in
            guard let ci = file.comments.firstIndex(where: { $0.id == commentID }) else {
                throw ReviewError.notFound(scene: scene, id: commentID)
            }
            guard let ri = file.comments[ci].replies.firstIndex(where: { $0.id == replyID }) else {
                throw ReviewError.notFound(scene: scene, id: replyID)
            }
            let reply = file.comments[ci].replies.remove(at: ri)
            file.comments[ci].updatedAt = Date()
            // A file another part of the thread still points at stays.
            let keep = Set(ReviewController.attachments(of: file.comments[ci]).map(\.path))
            return (ri, reply, keep)
        }
        let mine = removed.reply.attachments.filter { !removed.keep.contains($0.path) }
        let files = readAttachments(mine)
        for path in files.keys {
            if let url = containedAttachmentURL(path) { try? FileManager.default.removeItem(at: url) }
        }
        return DeletedReply(scene: scene, commentID: commentID, index: removed.index, reply: removed.reply, files: files)
    }

    /// Puts a deleted reply back at its old place in the thread.
    func restore(_ r: DeletedReply) throws {
        writeAttachments(r.files)
        try mutate(scene: r.scene) { file in
            guard let ci = file.comments.firstIndex(where: { $0.id == r.commentID }) else {
                throw ReviewError.notFound(scene: r.scene, id: r.commentID)
            }
            guard !file.comments[ci].replies.contains(where: { $0.id == r.reply.id }) else { return }
            let at = min(max(0, r.index), file.comments[ci].replies.count)
            file.comments[ci].replies.insert(r.reply, at: at)
        }
    }

    /// Contents of the regular files directly inside the attachments folder.
    private func readAttachments(_ list: [ReviewAttachment]) -> [String: Data] {
        var out: [String: Data] = [:]
        for a in list {
            guard let url = containedAttachmentURL(a.path),
                  (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular,
                  let data = try? Data(contentsOf: url) else { continue }
            out[a.path] = data
        }
        return out
    }

    private func writeAttachments(_ files: [String: Data]) {
        for (path, data) in files {
            guard let url = containedAttachmentURL(path), !FileManager.default.fileExists(atPath: url.path) else { continue }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}

extension ReviewController {
    /// Deletes a comment and its attachment files; the returned copy undoes it.
    @discardableResult
    func deleteKeepingCopy(_ id: String) throws -> DeletedComment {
        guard let scene else { throw ReviewError.io("no scene selected") }
        let d = try store.removeKeepingCopy(scene: scene, id: id)
        if selection == id { selection = nil; threadOpen = false }
        if compareID == id { compareID = nil }
        reload()
        return d
    }

    /// Undo of a delete: the comment comes back, selected.
    func restore(_ d: DeletedComment) throws {
        try store.restore(d)
        reload()
        if d.scene == scene { selection = d.comment.id }
    }

    /// Deletes one reply from a thread; the returned copy undoes it.
    @discardableResult
    func deleteReply(_ commentID: String, replyID: String) throws -> DeletedReply {
        guard let scene else { throw ReviewError.io("no scene selected") }
        let r = try store.removeReply(scene: scene, commentID: commentID, replyID: replyID)
        reload()
        return r
    }

    func restore(_ r: DeletedReply) throws {
        try store.restore(r)
        reload()
    }

    /// Replies a person may delete: anyone's own words, never Claude's or Studio's notes.
    nonisolated static func canDelete(_ reply: ReviewReply) -> Bool {
        reply.author.kind == .human
    }
}
