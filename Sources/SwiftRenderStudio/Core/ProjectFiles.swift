import Foundation
import SwiftRenderKit

// MARK: - Project files: Trash, put back, find and duplicate scenes
//
// Everything Studio removes from disk goes to the Trash (never `rm`), and only after
// `ProjectTrash.validate` agrees the file is a plain file strictly inside the project:
// symlinked folders are resolved first, so a link pointing outside can't smuggle a path
// out, and `.git`, `.build`, `.swiftpm` and other hidden folders are off limits. Every
// move records where the file went, so Edit › Undo can put it back.

enum ProjectFileError: Error, CustomStringConvertible, Equatable {
    case outsideProject(String)
    case notAFile(String)
    case hidden(String)
    case wrongKind(String)
    case missing(String)
    case occupied(String)
    case notInTrash(String)
    case cantDuplicate(String)

    var description: String {
        switch self {
        case .outsideProject(let p): return "\(p) isn't inside this project"
        case .notAFile(let p): return "\(p) isn't a plain file"
        case .hidden(let p): return "\(p) is in a folder Studio doesn't touch"
        case .wrongKind(let p): return "\(p) isn't the kind of file this can remove"
        case .missing(let p): return "\(p) doesn't exist anymore"
        case .occupied(let p): return "there's already a file at \(p)"
        case .notInTrash(let p): return "Studio doesn't know where \(p) went in the Trash"
        case .cantDuplicate(let why): return why
        }
    }
}

/// Where a trashed file came from and where it went.
struct TrashedFile: Equatable, Sendable {
    var original: URL
    /// nil when the system didn't say (the file is in the Trash, but Undo can't find it).
    var trashed: URL?
}

/// Moves project files to the Trash and back, refusing anything outside the project.
struct ProjectTrash {
    let root: URL
    /// The actual move to the Trash; returns where the file went. Tests swap in a folder.
    var mover: (URL) throws -> URL? = { url in
        var out: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &out)
        return out as URL?
    }

    init(root: URL) { self.root = root }

    init(root: URL, mover: @escaping (URL) throws -> URL?) {
        self.root = root
        self.mover = mover
    }

    private static func canonical(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// The file `url` names, resolved, when it's a regular file (not a link, not a folder)
    /// strictly inside the project, outside every hidden folder, inside `within` when given,
    /// and (when given) has one of `extensions`. Throws a plain-language reason otherwise.
    func validate(_ url: URL, within: URL? = nil, extensions: Set<String>? = nil) throws -> URL {
        let shown = url.lastPathComponent
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("\0") else { throw ProjectFileError.notAFile(shown) }
        let rootPath = Self.canonical(root)
        // Resolve the folder (symlinks included), then put the name back: the file itself
        // must not be a link, so it's never resolved.
        let parent = Self.canonical(url.deletingLastPathComponent())
        let full = parent == "/" ? "/" + name : parent + "/" + name
        guard full.hasPrefix(rootPath + "/") else { throw ProjectFileError.outsideProject(shown) }
        let relative = full.dropFirst(rootPath.count + 1).split(separator: "/")
        if relative.contains(where: { $0.hasPrefix(".") }) { throw ProjectFileError.hidden(shown) }
        if let within {
            let w = Self.canonical(within)
            guard w.hasPrefix(rootPath + "/") || w == rootPath, full.hasPrefix(w + "/") else {
                throw ProjectFileError.wrongKind(shown)
            }
        }
        if let extensions, !extensions.contains(URL(fileURLWithPath: full).pathExtension.lowercased()) {
            throw ProjectFileError.wrongKind(shown)
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: full) else { throw ProjectFileError.missing(shown) }
        guard (attrs[.type] as? FileAttributeType) == .typeRegular else { throw ProjectFileError.notAFile(shown) }
        return URL(fileURLWithPath: full)
    }

    /// Validates, then moves the file to the Trash.
    func trash(_ url: URL, within: URL? = nil, extensions: Set<String>? = nil) throws -> TrashedFile {
        let file = try validate(url, within: within, extensions: extensions)
        let went = try mover(file)
        return TrashedFile(original: file, trashed: went)
    }

    /// Puts a trashed file back where it was. Never overwrites: a file now at the original
    /// path wins, and the trashed copy stays in the Trash.
    @discardableResult
    func restore(_ t: TrashedFile) throws -> URL {
        let shown = t.original.lastPathComponent
        guard let from = t.trashed else { throw ProjectFileError.notInTrash(shown) }
        let fm = FileManager.default
        guard fm.fileExists(atPath: from.path) else { throw ProjectFileError.notInTrash(shown) }
        guard !fm.fileExists(atPath: t.original.path) else { throw ProjectFileError.occupied(shown) }
        // The destination is still checked against the project (its folder may have moved).
        let parent = Self.canonical(t.original.deletingLastPathComponent())
        guard (parent + "/").hasPrefix(Self.canonical(root) + "/") else { throw ProjectFileError.outsideProject(shown) }
        try fm.createDirectory(at: t.original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: from, to: t.original)
        return t.original
    }
}

// MARK: - Scene files

enum SceneFiles {
    static let sceneProtocols: Set<String> = ["RenderScene", "AudioReactiveScene", "PropsScene", "PropsAudioScene"]
    private static let declaration = try! NSRegularExpression(pattern: #"public\s+struct\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([^{]+)\{"#)

    /// Scenes a Swift file declares, the way the registry plugin finds them.
    static func scenesDeclared(in source: String) -> [String] {
        let ns = source as NSString
        return declaration.matches(in: source, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let clause = ns.substring(with: m.range(at: 2))
            let conforms = clause.split(whereSeparator: { ",: \n\t".contains($0) }).map(String.init)
            return conforms.contains(where: sceneProtocols.contains) ? ns.substring(with: m.range(at: 1)) : nil
        }
    }

    /// The file that declares `scene`: what the host reported, else a scan of `Sources/`.
    static func locate(scene: String, reported: String?, root: URL) -> URL? {
        if let reported, FileManager.default.fileExists(atPath: reported) { return URL(fileURLWithPath: reported) }
        return scan(scene: scene, root: root)
    }

    /// Looks through `Sources/**/*.swift` for `public struct <scene>: …Scene`.
    static func scan(scene: String, root: URL) -> URL? {
        let sources = root.appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains(scene) else { continue }
            if scenesDeclared(in: text).contains(scene) { return url }
        }
        return nil
    }

    /// A name for a copy of `scene` that no scene, file or word in its source uses yet:
    /// "HeroCopy", then "HeroCopy2", "HeroCopy3", …
    static func copyName(for scene: String, taken: Set<String>, folder: URL, source: String) -> String {
        var n = 1
        while true {
            let name = scene + "Copy" + (n == 1 ? "" : "\(n)")
            let file = folder.appendingPathComponent(name + ".swift")
            if !taken.contains(name), !FileManager.default.fileExists(atPath: file.path),
               source.range(of: #"\b\#(name)\b"#, options: .regularExpression) == nil {
                return name
            }
            n += 1
        }
    }

    /// The copy's source: every whole-word `scene` renamed to `newName`. Refuses (with a
    /// reason) when the file declares anything else at the top level that isn't `private`
    /// or `fileprivate` — the copy would clash with the original and break the build.
    static func duplicateSource(_ source: String, scene: String, as newName: String) throws -> String {
        if let clash = sharedDeclaration(in: source, scene: scene) {
            throw ProjectFileError.cantDuplicate(
                "\(scene)'s file also declares \(clash), which a copy would clash with. Duplicate it in your editor instead.")
        }
        let pattern = #"\b\#(NSRegularExpression.escapedPattern(for: scene))\b"#
        let re = try NSRegularExpression(pattern: pattern)
        let ns = source as NSString
        return re.stringByReplacingMatches(in: source, range: NSRange(location: 0, length: ns.length),
                                           withTemplate: NSRegularExpression.escapedTemplate(for: newName))
    }

    /// The first top-level declaration (column 0) other than the scene itself, its
    /// extensions, imports and private/fileprivate helpers; nil when there's none.
    static func sharedDeclaration(in source: String, scene: String) -> String? {
        let keywords: Set<String> = ["struct", "class", "enum", "actor", "protocol", "typealias", "func", "let", "var",
                                     "extension", "macro", "precedencegroup", "operator"]
        let modifiers: Set<String> = ["public", "internal", "private", "fileprivate", "final", "open", "nonisolated",
                                      "indirect", "static", "prefix", "postfix", "infix", "package"]
        var inBlockComment = false
        for raw in source.components(separatedBy: .newlines) {
            if inBlockComment {
                if raw.contains("*/") { inBlockComment = false }
                continue
            }
            guard let first = raw.first, !first.isWhitespace else { continue }
            var line = Substring(raw)
            if line.hasPrefix("/*") { if !line.contains("*/") { inBlockComment = true }; continue }
            if line.hasPrefix("//") || line.hasPrefix("#") || line.hasPrefix("import ") || line.hasPrefix("@_exported") { continue }
            // Attributes: `@MainActor`, `@available(macOS 14, *)`.
            while line.hasPrefix("@") {
                var depth = 0, end = line.endIndex
                for i in line.indices.dropFirst() {
                    let ch = line[i]
                    if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1 }
                    else if depth == 0, ch == " " || ch == "\t" { end = i; break }
                }
                line = line[end...].drop(while: { $0 == " " || $0 == "\t" })
            }
            let words = line.split(whereSeparator: { " \t:<{(".contains($0) }).map(String.init)
            guard !words.isEmpty else { continue }
            var mods: Set<String> = []
            var i = 0
            while i < words.count, modifiers.contains(words[i]) || words[i].hasPrefix("private(") {
                mods.insert(words[i].hasPrefix("private(") ? "private" : words[i]); i += 1
            }
            guard i < words.count, keywords.contains(words[i]) else { continue }
            let keyword = words[i]
            let name = i + 1 < words.count ? words[i + 1] : ""
            if mods.contains("private") || mods.contains("fileprivate") { continue }
            if keyword == "extension", name == scene { continue }
            if ["struct", "class", "enum", "actor"].contains(keyword), name == scene { continue }
            return "\(keyword) \(name)".trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
