import Foundation

// MARK: - Output paths
//
// Every writer that replaces a user-named output (the CLI's `--out`, Recorder,
// MP4Assembler) goes through here, so a missing or mistyped `--out` can never
// turn "replace the old render" into "recursively delete a directory".

/// A rejected output path, with a message that says how to fix it.
public struct OutputPathError: Error, CustomStringConvertible, Equatable {
    /// Human-readable message.
    public var description: String
    /// Creates an error with message `d`.
    public init(_ d: String) { description = d }
}

/// Safety checks for user-named output files before they are replaced.
public enum OutputPath {
    /// Checks a user-supplied output path: not empty, not ending in "/", and not an
    /// existing directory (the old output is replaced, so it must be a file).
    @discardableResult
    public static func validate(_ path: String, flag: String = "--out") throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OutputPathError("\(flag) needs a file path") }
        guard !path.hasSuffix("/") else {
            throw OutputPathError("\(flag) \(path) names a directory — give a file path (e.g. \(path)render.mp4)")
        }
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        if isDirectory(url) {
            throw OutputPathError("\(flag) \(path) is an existing directory — give a file path inside it")
        }
        return url
    }

    /// Removes the previous output at `url` before a new one is written. Only a regular
    /// file (or a symlink, which is unlinked, never followed) is removed; a directory or
    /// anything else throws instead of being deleted. A missing path is fine.
    public static func removeExistingFile(at url: URL) throws {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            if errno == ENOENT { return }
            throw OutputPathError("cannot inspect output \(url.path): \(String(cString: strerror(errno)))")
        }
        let type = st.st_mode & S_IFMT
        guard type == S_IFREG || type == S_IFLNK else {
            throw OutputPathError(type == S_IFDIR
                ? "output path \(url.path) is a directory — refusing to replace it"
                : "output path \(url.path) is not a regular file — refusing to replace it")
        }
        guard unlink(url.path) == 0 || errno == ENOENT else {
            throw OutputPathError("cannot replace \(url.path): \(String(cString: strerror(errno)))")
        }
    }

    /// True when `url` exists and is a directory (following symlinks).
    public static func isDirectory(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }
}
