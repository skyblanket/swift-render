import Foundation
import SwiftRenderKit

// MARK: - Checkpoints   // S8
//
// To implement (studio-ux §2.5) — never touches the user's branch:
//   create: `git stash create` (or HEAD when clean) → `git update-ref refs/swift-render/checkpoints/<run> <sha>`
//   diffStat: `git diff --stat <sha> -- <files>`
//   revert: `git checkout <sha> -- <files>`; agent-created files go to the Trash (NSWorkspace.recycle).

struct Checkpoint: Equatable, Sendable {
    let ref: String
    let sha: String

    enum CheckpointError: Error { case notImplemented }

    static func create(project: Project, runID: String) throws -> Checkpoint {
        throw CheckpointError.notImplemented
    }

    func diffStat(project: Project, files: [String]) throws -> String {
        throw CheckpointError.notImplemented
    }

    func revert(project: Project, files: [String], created: [String]) throws {
        throw CheckpointError.notImplemented
    }
}
