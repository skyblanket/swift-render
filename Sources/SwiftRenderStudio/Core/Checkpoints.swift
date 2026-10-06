import Foundation
import SwiftRenderKit

// MARK: - Checkpoints   // S8
//
// Taken before an agent run that may edit files; never touches the user's branch,
// index or stash stack (studio-ux §2.5):
//   create:  `git stash create` (a dangling commit of the tracked working tree; HEAD when
//            clean) → `git update-ref refs/swift-render/checkpoints/<run> <sha>`. Untracked
//            files aren't in that commit, so their names are recorded, and small ones are
//            stored as blobs (`git hash-object -w`) so an agent edit to one can be undone.
//   diff:    `git diff --numstat <sha> -- <files>` (+ line counts for files created since).
//   revert:  `git restore --source <sha> --worktree -- <tracked>` (worktree only, the index
//            is left alone), untracked files rewritten from their blobs, files the agent
//            created moved to the Trash — never deleted.

struct Checkpoint: Equatable, Sendable {
    /// `refs/swift-render/checkpoints/<run>`.
    let ref: String
    let sha: String
    /// Repository top level (paths below are relative to it).
    let top: String
    /// Untracked, non-ignored files at checkpoint time.
    var untracked: Set<String> = []
    /// Blob ids for the untracked files small enough to keep.
    var untrackedBlobs: [String: String] = [:]

    enum CheckpointError: Error, CustomStringConvertible {
        case notARepository
        case git(String)
        var description: String {
            switch self {
            case .notARepository: return "not a git repository — runs can't be reverted"
            case .git(let why): return why
            }
        }
    }

    /// Lines added/removed in one file since the checkpoint.
    struct FileStat: Equatable, Sendable, Hashable {
        var path: String
        var added: Int
        var removed: Int
        /// Not in the checkpoint at all: the agent created it.
        var created = false
        var label: String { created ? "new +\(added)" : "+\(added) −\(removed)" }
    }

    static let refPrefix = "refs/swift-render/checkpoints/"
    static let blobLimit = 2 << 20
    static let untrackedLimit = 500

    static func create(project: Project, runID: String) throws -> Checkpoint {
        let cwd = Checkpoint.realpath(project.root)
        guard let top = try? git(["rev-parse", "--show-toplevel"], cwd: cwd).trimmingCharacters(in: .whitespacesAndNewlines),
              !top.isEmpty else { throw CheckpointError.notARepository }
        var sha = try git(["stash", "create", "swift-render checkpoint \(runID)"], cwd: cwd)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if sha.isEmpty { sha = try git(["rev-parse", "HEAD"], cwd: cwd).trimmingCharacters(in: .whitespacesAndNewlines) }
        let ref = refPrefix + runID
        _ = try git(["update-ref", ref, sha], cwd: cwd)
        var cp = Checkpoint(ref: ref, sha: sha, top: top)

        let topURL = URL(fileURLWithPath: top, isDirectory: true)
        let others = try git(["ls-files", "--others", "--exclude-standard", "-z"], cwd: topURL)
            .split(separator: "\0").map(String.init)
        cp.untracked = Set(others)
        let small = others.prefix(untrackedLimit).filter { p in
            let size = (try? FileManager.default.attributesOfItem(atPath: topURL.appendingPathComponent(p).path)[.size]) as? Int
            return (size ?? .max) <= blobLimit
        }
        if !small.isEmpty {
            let ids = try git(["hash-object", "-w", "--stdin-paths"], cwd: topURL, stdin: small.joined(separator: "\n") + "\n")
                .split(separator: "\n").map(String.init)
            if ids.count == small.count { cp.untrackedBlobs = Dictionary(uniqueKeysWithValues: zip(small, ids)) }
        }
        return cp
    }

    /// Path relative to the repository top, or nil when outside it.
    func relative(_ path: String) -> String? {
        // Canonicalize the directory: the file itself may not exist (yet, or any more).
        let url = URL(fileURLWithPath: path)
        let abs = Checkpoint.realpath(url.deletingLastPathComponent()).appendingPathComponent(url.lastPathComponent).path
        let t = Checkpoint.realpath(URL(fileURLWithPath: top, isDirectory: true)).path
        guard abs.hasPrefix(t + "/") else { return nil }
        return String(abs.dropFirst(t.count + 1))
    }

    private var topURL: URL { URL(fileURLWithPath: top, isDirectory: true) }

    /// Present in the checkpoint commit's tree.
    func isTracked(_ rel: String) -> Bool {
        (try? Self.git(["cat-file", "-e", "\(sha):\(rel)"], cwd: topURL)) != nil
    }

    func diffStat(files: [String]) throws -> [FileStat] {
        let rels = Array(Set(files.compactMap(relative))).sorted()
        guard !rels.isEmpty else { return [] }
        var stats: [String: FileStat] = [:]
        let out = try Self.git(["diff", "--numstat", sha, "--"] + rels, cwd: topURL)
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { continue }
            stats[parts[2]] = FileStat(path: parts[2], added: Int(parts[0]) ?? 0, removed: Int(parts[1]) ?? 0)
        }
        for rel in rels where stats[rel] == nil && !isTracked(rel) {
            let url = topURL.appendingPathComponent(rel)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if let blob = untrackedBlobs[rel] {
                // Untracked before the run: diff against the stored blob.
                let before = (try? Self.git(["cat-file", "blob", blob], cwd: topURL)) ?? ""
                let (a, r) = Self.lineDelta(before, text)
                if a + r > 0 { stats[rel] = FileStat(path: rel, added: a, removed: r) }
            } else if !untracked.contains(rel) {
                stats[rel] = FileStat(path: rel, added: text.split(separator: "\n", omittingEmptySubsequences: false).count,
                                      removed: 0, created: true)
            }
        }
        return rels.compactMap { stats[$0] }
    }

    /// Puts `files` back as they were at the checkpoint. Returns what couldn't be restored.
    @discardableResult
    func revert(files: [String],
                trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws -> [String] {
        let rels = Array(Set(files.compactMap(relative))).sorted()
        var tracked: [String] = []
        var skipped: [String] = []
        for rel in rels {
            let url = topURL.appendingPathComponent(rel)
            if isTracked(rel) {
                tracked.append(rel)
            } else if let blob = untrackedBlobs[rel] {
                let data = try Self.gitData(["cat-file", "blob", blob], cwd: topURL)
                try data.write(to: url, options: .atomic)
            } else if untracked.contains(rel) {
                skipped.append(rel)         // untracked and too large to have been kept
            } else if FileManager.default.fileExists(atPath: url.path) {
                try trash(url)
            }
        }
        if !tracked.isEmpty {
            _ = try Self.git(["restore", "--source", sha, "--worktree", "--"] + tracked, cwd: topURL)
        }
        return skipped
    }

    /// Drops the ref (the commit becomes unreachable and git gc may collect it).
    func delete() {
        _ = try? Self.git(["update-ref", "-d", ref], cwd: topURL)
    }

    /// realpath(3): /tmp → /private/tmp, symlinks resolved (git prints real paths).
    static func realpath(_ url: URL) -> URL {
        guard let p = Darwin.realpath(url.path, nil) else { return url }
        defer { free(p) }
        return URL(fileURLWithPath: String(cString: p), isDirectory: true)
    }

    // MARK: git

    @discardableResult
    static func git(_ args: [String], cwd: URL, stdin: String? = nil) throws -> String {
        String(decoding: try gitData(args, cwd: cwd, stdin: stdin), as: UTF8.self)
    }

    static func gitData(_ args: [String], cwd: URL, stdin: String? = nil) throws -> Data {
        let exe = ToolPaths.resolveBlocking("git") ?? URL(fileURLWithPath: "/usr/bin/git")
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"         // don't contend with the user's git for index.lock
        p.environment = env
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = stdin == nil ? FileHandle.nullDevice : inp
        try p.run()
        if let stdin {
            try? inp.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
            try? inp.fileHandleForWriting.close()
        }
        // Read both pipes before waiting: a full pipe would block the child forever.
        let errBox = DataBox()
        let reader = Thread { errBox.data = err.fileHandleForReading.readDataToEndOfFile() }
        reader.start()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        while !errBox.done { usleep(1000) }
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: errBox.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CheckpointError.git("git \(args.first ?? ""): \(msg.isEmpty ? "exit \(p.terminationStatus)" : msg)")
        }
        return data
    }

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _data: Data?
        var data: Data {
            get { lock.lock(); defer { lock.unlock() }; return _data ?? Data() }
            set { lock.lock(); _data = newValue; lock.unlock() }
        }
        var done: Bool { lock.lock(); defer { lock.unlock() }; return _data != nil }
    }

    /// Lines only in `b` / only in `a` (multiset difference; enough for a +/− badge).
    static func lineDelta(_ a: String, _ b: String) -> (added: Int, removed: Int) {
        var counts: [Substring: Int] = [:]
        for l in a.split(separator: "\n", omittingEmptySubsequences: false) { counts[l, default: 0] += 1 }
        var added = 0
        for l in b.split(separator: "\n", omittingEmptySubsequences: false) {
            if let c = counts[l], c > 0 { counts[l] = c - 1 } else { added += 1 }
        }
        return (added, counts.values.reduce(0, +))
    }
}
