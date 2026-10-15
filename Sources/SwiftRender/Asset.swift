import AppKit
import SwiftUI

/// Load a PNG/JPEG resource bundled via SPM `.process("Resources")`.
/// Returns a SwiftUI Image, falling back to a placeholder if missing.
public func bundledImage(_ name: String, ext: String = "png") -> Image {
    if let url = Bundle.module.url(forResource: name, withExtension: ext),
       let nsImage = NSImage(contentsOf: url) {
        return Image(nsImage: nsImage)
    }
    fputs("[swift-render] WARN: missing asset \(name).\(ext) in Bundle.module\n", stderr)
    return Image(systemName: "questionmark.square")
}

/// Resolves file paths used by scenes (samples, video, images, voiceover caches).
///
/// Relative paths are tried against, in order: the working directory, `<cwd>/assets`,
/// the package root, `<root>/assets`, then `extraSearchPaths`. So a scene can say
/// `sample("openear-foley/click_1.wav", …)` or `VideoClip("clips/demo.mp4", …)`.
public enum AssetPaths {
    /// Package root of this checkout (derived from this source file's location).
    public static let packageRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SwiftRender
        .deletingLastPathComponent()   // Sources
        .deletingLastPathComponent()   // root

    /// Extra directories searched after the defaults, in order.
    nonisolated(unsafe) public static var extraSearchPaths: [URL] = []

    /// The directories relative paths are tried against, in search order.
    public static var searchPaths: [URL] {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return [cwd, cwd.appendingPathComponent("assets"),
                packageRoot, packageRoot.appendingPathComponent("assets")] + extraSearchPaths
    }

    /// The first existing file for `path`, or nil.
    public static func resolve(_ path: String) -> URL? {
        let fm = FileManager.default
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return fm.fileExists(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil
        }
        for base in searchPaths {
            let url = base.appendingPathComponent(expanded)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}

/// Small thread-safe memo used by the media caches.
///
/// File-backed entries pass a `version` (see `FileStamp`): a hit only counts when the
/// version still matches, so a long-lived process (Studio's render host) re-decodes a
/// sample, image or video after the file on disk changes instead of serving the old one.
final class LockedCache<Key: Hashable, Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [Key: (version: String, value: Value)] = [:]
    private var order: [Key] = []
    private let limit: Int

    init(limit: Int = .max) { self.limit = limit }

    func value(_ key: Key, version: String = "", orInsert make: () throws -> Value) rethrows -> Value {
        lock.lock()
        if let hit = store[key], hit.version == version { lock.unlock(); return hit.value }
        lock.unlock()
        let v = try make()
        lock.lock()
        if let old = store[key] {
            if old.version != version { store[key] = (version, v) }
        } else {
            store[key] = (version, v)
            order.append(key)
            if order.count > limit { store.removeValue(forKey: order.removeFirst()) }
        }
        lock.unlock()
        return v
    }
}

/// Identity of a file's current contents for cache keys: size, modification time
/// (nanoseconds) and inode — or "missing".
enum FileStamp {
    static func of(_ path: String) -> String {
        var st = stat()
        guard stat(path, &st) == 0 else { return "missing" }
        return "\(st.st_size):\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec):\(st.st_ino)"
    }
}

/// A box for handing a result out of a completion handler we block on.
final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}
