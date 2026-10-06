import Foundation
import SwiftRenderKit

// MARK: - Checkpoints
//
// Taken before an agent run that may edit files; never touches the user's branch,
// index or stash stack (studio-ux §2.5):
//   create:  `git stash create` (a dangling commit of the tracked working tree; HEAD when
//            clean; a temporary-index commit when there is no HEAD yet or a merge is in
//            progress) → `git update-ref refs/swift-render/checkpoints/<run> <sha>`.
//            Untracked and ignored files aren't in that commit, so their names are
//            recorded, small ones are stored byte for byte as blobs (`hash-object -w
//            --no-filters`) and symlinks by their target, so an agent edit can be undone.
//   diff:    `git diff --numstat <sha> -- <files>` (+ line counts for files created since).
//   revert:  first the current content of every touched file is committed under
//            `refs/swift-render/pre-revert/<run>` (so the revert itself can be undone),
//            then `git restore --source <sha> --worktree -- <tracked>` (worktree only,
//            the index is left alone), untracked/ignored files rewritten from their
//            blobs, and only files that provably did not exist at checkpoint time moved
//            to the Trash — never deleted. Anything that can't be restored (ignored
//            without a blob, inside a submodule or nested repository, too large) is left
//            in place and reported. Every git call treats paths literally (no globs).

struct Checkpoint: Equatable, Sendable {
    /// `refs/swift-render/checkpoints/<run>`.
    let ref: String
    let sha: String
    /// Repository top level (paths below are relative to it).
    let top: String
    /// Untracked, non-ignored entries at checkpoint time (a trailing "/" marks a
    /// directory git doesn't descend into: a nested repository).
    var untracked: Set<String> = []
    /// Blob ids for the untracked files small enough to keep.
    var untrackedBlobs: [String: String] = [:]
    /// Ignored entries at checkpoint time (`--directory`: a wholly ignored directory is
    /// one entry ending in "/").
    var ignored: Set<String> = []
    /// Blob ids for the small ignored files (`.env`, `Secrets.swift`…).
    var ignoredBlobs: [String: String] = [:]
    /// Untracked or ignored symlinks → their target, recreated as links on revert.
    var links: [String: String] = [:]

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

    /// What a revert did.
    struct RevertResult: Equatable, Sendable {
        struct Skip: Equatable, Sendable {
            var path: String
            var reason: String
        }
        /// Repository-relative paths put back (or, for created files, moved to the Trash).
        var restored: [String] = []
        var trashed: [String] = []
        var skipped: [Skip] = []
        /// `refs/swift-render/pre-revert/<run>`: the touched files as they were just before.
        var backupRef: String?
    }

    static let refPrefix = "refs/swift-render/checkpoints/"
    static let backupPrefix = "refs/swift-render/pre-revert/"
    static let blobLimit = 2 << 20
    static let untrackedLimit = 500
    static let ignoredBlobLimit = 256 << 10
    static let ignoredLimit = 200

    static func create(project: Project, runID: String) throws -> Checkpoint {
        let cwd = Checkpoint.realpath(project.root)
        guard let top = try? git(["rev-parse", "--show-toplevel"], cwd: cwd).trimmingCharacters(in: .whitespacesAndNewlines),
              !top.isEmpty else { throw CheckpointError.notARepository }
        let topURL = URL(fileURLWithPath: top, isDirectory: true)
        let sha = try snapshotCommit(topURL, message: "swift-render checkpoint \(runID)")
        let ref = refPrefix + runID
        _ = try git(["update-ref", ref, sha], cwd: cwd)
        var cp = Checkpoint(ref: ref, sha: sha, top: top)

        let others = try git(["ls-files", "--others", "--exclude-standard", "-z"], cwd: topURL)
            .split(separator: "\0").map(String.init)
        cp.untracked = Set(others)
        let ignored = try git(["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"], cwd: topURL)
            .split(separator: "\0").map(String.init)
        cp.ignored = Set(ignored)

        let fm = FileManager.default
        func attributes(_ rel: String) -> [FileAttributeKey: Any]? {
            try? fm.attributesOfItem(atPath: topURL.appendingPathComponent(rel).path)     // lstat: links themselves
        }
        func keep(_ rels: some Sequence<String>, limit: Int) -> [String] {
            rels.filter { rel in
                guard !rel.hasSuffix("/"), let a = attributes(rel) else { return false }
                if a[.type] as? FileAttributeType == .typeSymbolicLink {
                    if let dest = try? fm.destinationOfSymbolicLink(atPath: topURL.appendingPathComponent(rel).path) {
                        cp.links[rel] = dest
                    }
                    return false
                }
                return a[.type] as? FileAttributeType == .typeRegular && ((a[.size] as? Int) ?? .max) <= limit
            }
        }
        cp.untrackedBlobs = hashObjects(keep(others.prefix(untrackedLimit), limit: blobLimit), top: topURL)
        cp.ignoredBlobs = hashObjects(keep(ignored.prefix(ignoredLimit * 4), limit: ignoredBlobLimit).prefix(ignoredLimit), top: topURL)
        return cp
    }

    /// The commit a checkpoint points at: `git stash create` (HEAD when clean). Without a
    /// HEAD (fresh `git init`) or with unmerged paths (a merge in progress) it fails, so
    /// the tracked working tree is committed through a temporary copy of the index.
    private static func snapshotCommit(_ top: URL, message: String) throws -> String {
        if let sha = try? git(["stash", "create", message], cwd: top).trimmingCharacters(in: .whitespacesAndNewlines) {
            if !sha.isEmpty { return sha }
            if let head = try? git(["rev-parse", "--verify", "-q", "HEAD"], cwd: top)
                .trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty { return head }
        }
        let indexPath = try git(["rev-parse", "--git-path", "index"], cwd: top).trimmingCharacters(in: .whitespacesAndNewlines)
        let index = URL(fileURLWithPath: indexPath, relativeTo: top)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sr-checkpoint-\(UUID().uuidString).index")
        defer { try? FileManager.default.removeItem(at: tmp) }
        if FileManager.default.fileExists(atPath: index.path) { try FileManager.default.copyItem(at: index, to: tmp) }
        let env = ["GIT_INDEX_FILE": tmp.path]
        _ = try git(["add", "-u", "--", "."], cwd: top, env: env)        // tracked files as they are now
        let tree = try git(["write-tree"], cwd: top, env: env).trimmingCharacters(in: .whitespacesAndNewlines)
        var args = ["commit-tree", tree, "-m", message]
        if let head = try? git(["rev-parse", "--verify", "-q", "HEAD"], cwd: top).trimmingCharacters(in: .whitespacesAndNewlines),
           !head.isEmpty { args += ["-p", head] }
        return try git(args, cwd: top, env: identityEnv).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// commit-tree needs an identity; a fresh machine may have none configured.
    private static let identityEnv: [String: String] = {
        let env = ProcessInfo.processInfo.environment
        var e: [String: String] = [:]
        if env["GIT_AUTHOR_NAME"] == nil { e["GIT_AUTHOR_NAME"] = "swift-render studio" }
        if env["GIT_AUTHOR_EMAIL"] == nil { e["GIT_AUTHOR_EMAIL"] = "studio@swift-render.invalid" }
        if env["GIT_COMMITTER_NAME"] == nil { e["GIT_COMMITTER_NAME"] = "swift-render studio" }
        if env["GIT_COMMITTER_EMAIL"] == nil { e["GIT_COMMITTER_EMAIL"] = "studio@swift-render.invalid" }
        return e
    }()

    /// `git hash-object -w --no-filters` (the bytes as they are on disk: no CRLF or LFS
    /// clean filter). One call for all; one per file if that fails (an unreadable file
    /// doesn't cost the others their backup).
    static func hashObjects(_ rels: some Collection<String>, top: URL) -> [String: String] {
        let rels = Array(rels)
        guard !rels.isEmpty else { return [:] }
        if let out = try? git(["hash-object", "-w", "--no-filters", "--stdin-paths"], cwd: top,
                              stdin: rels.joined(separator: "\n") + "\n") {
            let ids = out.split(separator: "\n").map(String.init)
            if ids.count == rels.count { return Dictionary(uniqueKeysWithValues: zip(rels, ids)) }
        }
        var result: [String: String] = [:]
        for rel in rels {
            if let id = try? git(["hash-object", "-w", "--no-filters", "--", rel], cwd: top)
                .trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty { result[rel] = id }
        }
        return result
    }

    /// Path relative to the repository top, or nil when outside it. An existing file is
    /// resolved itself, so `sources/a.swift` names the tracked `Sources/A.swift` on a
    /// case-insensitive volume; a missing one by its directory.
    func relative(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let abs: String
        var isLink = false
        if let a = try? FileManager.default.attributesOfItem(atPath: url.path) {
            isLink = a[.type] as? FileAttributeType == .typeSymbolicLink
        }
        if !isLink, FileManager.default.fileExists(atPath: url.path) {
            abs = Checkpoint.realpath(url).path
        } else {
            // A link is named by its own path (resolving it would name its target).
            abs = Checkpoint.realpath(url.deletingLastPathComponent()).appendingPathComponent(url.lastPathComponent).path
        }
        let t = Checkpoint.realpath(URL(fileURLWithPath: top, isDirectory: true)).path
        guard abs.hasPrefix(t + "/") else { return nil }
        return String(abs.dropFirst(t.count + 1))
    }

    private var topURL: URL { URL(fileURLWithPath: top, isDirectory: true) }

    /// Repository-relative paths for `files`, plus the in-repo target of any that is a
    /// symlink (a write through `link.json` changed the file it points at).
    func resolve(_ files: [String]) -> [String] {
        var rels: [String] = []
        for f in files {
            guard let rel = relative(f) else { continue }
            rels.append(rel)
            let url = topURL.appendingPathComponent(rel)
            if Self.isLink(url), let target = relative(Self.realpath(url).path), target != rel { rels.append(target) }
        }
        return rels
    }

    /// Present in the checkpoint commit's tree.
    func isTracked(_ rel: String) -> Bool {
        (try? Self.git(["cat-file", "-e", "\(sha):\(rel)"], cwd: topURL)) != nil
    }

    /// Where a path stood at checkpoint time.
    enum Origin: Equatable {
        case tracked
        case blob(String)
        case link(String)
        /// Existed, but there's no copy to restore it from.
        case unrestorable(String)
        /// Provably absent at checkpoint time.
        case new
    }

    func origin(_ rel: String) -> Origin {
        if let inside = enclosingGitlink(rel) { return .unrestorable("inside submodule \(inside)") }
        if isTracked(rel) { return .tracked }
        if let dest = links[rel] { return .link(dest) }
        if let blob = untrackedBlobs[rel] ?? ignoredBlobs[rel] { return .blob(blob) }
        if untracked.contains(rel) { return .unrestorable("untracked and too large to checkpoint") }
        if ignored.contains(rel) { return .unrestorable("ignored by git and not checkpointed") }
        for dir in Self.ancestors(rel) {
            if untracked.contains(dir + "/") { return .unrestorable("inside nested repository \(dir)") }
            if ignored.contains(dir + "/") { return .unrestorable("ignored by git and not checkpointed") }
        }
        return .new
    }

    /// The submodule (gitlink in the checkpoint tree) containing `rel`, if any.
    private func enclosingGitlink(_ rel: String) -> String? {
        let dirs = Self.ancestors(rel)
        guard !dirs.isEmpty,
              let out = try? Self.git(["cat-file", "--batch-check"], cwd: topURL,
                                      stdin: dirs.map { "\(sha):\($0)" }.joined(separator: "\n") + "\n") else { return nil }
        for (dir, line) in zip(dirs, out.split(separator: "\n")) where line.split(separator: " ").dropFirst().first == "commit" {
            return dir
        }
        return nil
    }

    /// "a/b/c.swift" → ["a", "a/b"].
    static func ancestors(_ rel: String) -> [String] {
        let parts = rel.split(separator: "/").dropLast()
        return parts.indices.map { parts[...$0].joined(separator: "/") }
    }

    func diffStat(files: [String]) throws -> [FileStat] {
        let rels = Array(Set(resolve(files))).sorted()
        guard !rels.isEmpty else { return [] }
        var stats: [String: FileStat] = [:]
        let out = try Self.git(["diff", "--numstat", sha, "--"] + rels, cwd: topURL)
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { continue }
            stats[parts[2]] = FileStat(path: parts[2], added: Int(parts[0]) ?? 0, removed: Int(parts[1]) ?? 0)
        }
        for rel in rels where stats[rel] == nil {
            let url = topURL.appendingPathComponent(rel)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            switch origin(rel) {
            case .blob(let blob):
                // Untracked or ignored before the run: diff against the stored blob.
                let before = (try? Self.git(["cat-file", "blob", blob], cwd: topURL)) ?? ""
                let (a, r) = Self.lineDelta(before, text)
                if a + r > 0 { stats[rel] = FileStat(path: rel, added: a, removed: r) }
            case .new:
                stats[rel] = FileStat(path: rel, added: text.split(separator: "\n", omittingEmptySubsequences: false).count,
                                      removed: 0, created: true)
            case .tracked, .link, .unrestorable:
                break
            }
        }
        return rels.compactMap { stats[$0] }
    }

    /// Repository-relative paths that differ from the checkpoint now: tracked files changed
    /// or deleted, and untracked files that didn't exist then.
    func changedSince() -> [String] {
        var out = Set((try? Self.git(["diff", "--name-only", "-z", sha], cwd: topURL))?
            .split(separator: "\0").map(String.init) ?? [])
        let others = (try? Self.git(["ls-files", "--others", "--exclude-standard", "-z"], cwd: topURL))?
            .split(separator: "\0").map(String.init) ?? []
        for rel in others where !untracked.contains(rel) { out.insert(rel) }
        // Studio's own bookkeeping (comment claims, caches) changes on every run.
        let own = [".swift-render/reviews/", ".swift-render/cache/", ".swift-render/attachments/"]
        return out.filter { p in !own.contains { p.hasPrefix($0) } }.sorted()
    }

    /// What each file is now: a blob id (written to the object store, so it doubles as a
    /// backup), "link:<target>", or "" when absent. Compared at revert time to tell the
    /// agent's result from later edits.
    func fingerprint(files: [String]) -> [String: String] {
        let rels = Array(Set(resolve(files)))
        var result: [String: String] = [:]
        var regular: [String] = []
        let fm = FileManager.default
        for rel in rels {
            let path = topURL.appendingPathComponent(rel).path
            guard let a = try? fm.attributesOfItem(atPath: path) else { result[rel] = ""; continue }
            if a[.type] as? FileAttributeType == .typeSymbolicLink {
                result[rel] = "link:" + ((try? fm.destinationOfSymbolicLink(atPath: path)) ?? "")
            } else if a[.type] as? FileAttributeType == .typeRegular {
                regular.append(rel)
            } else {
                result[rel] = "other"
            }
        }
        result.merge(Self.hashObjects(regular, top: topURL)) { $1 }
        return result
    }

    /// Puts `files` back as they were at the checkpoint, except the `keep` set
    /// (repository-relative; e.g. files edited again since the run). The current content
    /// of everything it overwrites is committed under `backupRef` first.
    @discardableResult
    func revert(files: [String], keep: Set<String> = [], backupRef: String? = nil,
                trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws -> RevertResult {
        let rels = Array(Set(resolve(files))).sorted()
        var result = RevertResult()
        var plan: [(rel: String, origin: Origin)] = []
        for rel in rels {
            if keep.contains(rel) {
                result.skipped.append(.init(path: rel, reason: "changed since the run"))
                continue
            }
            let o = origin(rel)
            if case .unrestorable(let why) = o {
                result.skipped.append(.init(path: rel, reason: why))
            } else {
                plan.append((rel, o))
            }
        }
        if let backupRef, !plan.isEmpty {
            result.backupRef = try backup(plan.map(\.rel), ref: backupRef)
        }
        var tracked: [String] = []
        let fm = FileManager.default
        for (rel, o) in plan {
            let url = topURL.appendingPathComponent(rel)
            switch o {
            case .tracked:
                tracked.append(rel)
            case .blob(let blob):
                let data = try Self.gitData(["cat-file", "blob", blob], cwd: topURL)
                if Self.isLink(url) { try fm.removeItem(at: url) }       // write the file, not through a link
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                result.restored.append(rel)
            case .link(let dest):
                if (try? fm.attributesOfItem(atPath: url.path)) != nil { try fm.removeItem(at: url) }
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.createSymbolicLink(atPath: url.path, withDestinationPath: dest)
                result.restored.append(rel)
            case .new:
                if (try? fm.attributesOfItem(atPath: url.path)) != nil {
                    try trash(url)
                    result.trashed.append(rel)
                }
            case .unrestorable:
                break
            }
        }
        if !tracked.isEmpty {
            _ = try Self.git(["restore", "--source", sha, "--worktree", "--"] + tracked, cwd: topURL)
            result.restored += tracked
        }
        return result
    }

    /// Commits the current content of `rels` (on top of the checkpoint tree) to `ref`.
    private func backup(_ rels: [String], ref: String) throws -> String {
        let fm = FileManager.default
        var entries: [String] = []
        var regular: [String] = []
        for rel in rels {
            let path = topURL.appendingPathComponent(rel).path
            guard let a = try? fm.attributesOfItem(atPath: path) else {
                entries.append("0 \(String(repeating: "0", count: 40))\t\(rel)")      // absent now
                continue
            }
            if a[.type] as? FileAttributeType == .typeSymbolicLink,
               let dest = try? fm.destinationOfSymbolicLink(atPath: path),
               let id = try? Self.git(["hash-object", "-w", "--stdin"], cwd: topURL, stdin: dest)
                   .trimmingCharacters(in: .whitespacesAndNewlines) {
                entries.append("120000 \(id)\t\(rel)")
            } else if a[.type] as? FileAttributeType == .typeRegular {
                regular.append(rel)
            }
        }
        let ids = Self.hashObjects(regular, top: topURL)
        for rel in regular {
            guard let id = ids[rel] else { continue }
            let exec = fm.isExecutableFile(atPath: topURL.appendingPathComponent(rel).path)
            entries.append("\(exec ? "100755" : "100644") \(id)\t\(rel)")
        }
        let tmp = fm.temporaryDirectory.appendingPathComponent("sr-prerevert-\(UUID().uuidString).index")
        defer { try? fm.removeItem(at: tmp) }
        let env = ["GIT_INDEX_FILE": tmp.path]
        _ = try Self.git(["read-tree", sha], cwd: topURL, env: env)
        _ = try Self.git(["update-index", "--index-info"], cwd: topURL, stdin: entries.joined(separator: "\n") + "\n", env: env)
        let tree = try Self.git(["write-tree"], cwd: topURL, env: env).trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = try Self.git(["commit-tree", tree, "-p", sha, "-m", "swift-render: before reverting \(ref)"],
                                  cwd: topURL, env: Self.identityEnv).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try Self.git(["update-ref", ref, commit], cwd: topURL)
        return ref
    }

    private static func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    /// Drops the ref (the commit becomes unreachable and git gc may collect it).
    func delete() {
        _ = try? Self.git(["update-ref", "-d", ref], cwd: topURL)
    }

    /// realpath(3): /tmp → /private/tmp, symlinks resolved, on-disk letter case (git prints real paths).
    static func realpath(_ url: URL) -> URL {
        guard let p = Darwin.realpath(url.path, nil) else { return url }
        defer { free(p) }
        return URL(fileURLWithPath: String(cString: p), isDirectory: true)
    }

    // MARK: git

    @discardableResult
    static func git(_ args: [String], cwd: URL, stdin: String? = nil, env extra: [String: String] = [:]) throws -> String {
        String(decoding: try gitData(args, cwd: cwd, stdin: stdin, env: extra), as: UTF8.self)
    }

    static func gitData(_ args: [String], cwd: URL, stdin: String? = nil, env extra: [String: String] = [:]) throws -> Data {
        let exe = ToolPaths.resolveBlocking("git") ?? URL(fileURLWithPath: "/usr/bin/git")
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"         // don't contend with the user's git for index.lock
        env["GIT_LITERAL_PATHSPECS"] = "1"      // `Scene[ab].swift` is one file, not a glob over others
        env.merge(extra) { $1 }
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
