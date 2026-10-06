import Foundation

// MARK: - Asset paths inside props files
//
// `swift-render launch <app>` writes props to `<app>/.swift-render/launch/<Name>.json`
// with icon/screenshot paths relative to the scanned app root. A renderer whose
// working directory is somewhere else (Studio's host in another project, the CLI
// run from the swift-render repo) can't resolve those, and the film silently falls
// back to a monogram. These helpers find the root a props file's paths are
// relative to, and make them absolute for a host that doesn't run there.

public enum PropsAssets {
    /// The directory relative asset paths in `url` are relative to: for
    /// `<R>/.swift-render/launch/<N>.json`, the sibling `<N>.scan.json`'s `root`
    /// (when it exists), else `<R>`. nil for a props file anywhere else.
    public static func scannedRoot(forPropsFile url: URL) -> URL? {
        let file = url.standardizedFileURL
        let launchDir = file.deletingLastPathComponent()
        let dotDir = launchDir.deletingLastPathComponent()
        guard launchDir.lastPathComponent == "launch", dotDir.lastPathComponent == ".swift-render" else { return nil }
        let base = file.deletingPathExtension().lastPathComponent
        let scan = launchDir.appendingPathComponent("\(base).scan.json")
        if let data = try? Data(contentsOf: scan),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let root = obj["root"] as? String, !root.isEmpty {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
            }
        }
        return dotDir.deletingLastPathComponent().standardizedFileURL
    }

    /// Rewrites every relative `"path"` string in `json` that names an existing file
    /// under `root` to its absolute path. Returns `json` unchanged when nothing needed it
    /// (or it isn't a JSON object).
    public static func absolutizingPaths(in json: String, root: URL) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.mutableContainers]) else { return json }
        var changed = false
        func walk(_ value: Any) -> Any {
            if let dict = value as? [String: Any] {
                var out = dict
                for (k, v) in dict {
                    if k == "path", let p = v as? String, !p.isEmpty, !p.hasPrefix("/"), !p.hasPrefix("~") {
                        let abs = root.appendingPathComponent(p).standardizedFileURL
                        if FileManager.default.fileExists(atPath: abs.path) { out[k] = abs.path; changed = true }
                    } else {
                        out[k] = walk(v)
                    }
                }
                return out
            }
            if let list = value as? [Any] { return list.map(walk) }
            return value
        }
        let rewritten = walk(obj)
        guard changed,
              let out = try? JSONSerialization.data(withJSONObject: rewritten,
                                                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return json }
        return String(decoding: out, as: UTF8.self)
    }

    /// Props text for a host running in `projectRoot`: when the file was scanned from
    /// another root, its relative asset paths are made absolute so they still resolve.
    public static func read(_ url: URL, projectRoot: URL) throws -> String {
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let root = scannedRoot(forPropsFile: url),
              root.resolvingSymlinksInPath().path != projectRoot.standardizedFileURL.resolvingSymlinksInPath().path
        else { return text }
        return absolutizingPaths(in: text, root: root)
    }
}
