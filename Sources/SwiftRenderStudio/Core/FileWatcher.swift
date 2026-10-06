import CoreServices
import Foundation

// MARK: - File watcher
//
// FSEvents (recursive, file-level, survives atomic saves that replace the inode —
// unlike DispatchSource file sources) on the project root, classified into what
// Studio must do: rebuild, reopen, reload comments, or reload knobs. Events are
// debounced so an editor's save burst or an agent's multi-file edit is one build.

final class FileWatcher: @unchecked Sendable {
    struct Change: Equatable, Sendable {
        enum Kind: String, Sendable, CaseIterable {
            /// *.swift, *.metal, Plugins/**, anything under Sources/ → rebuild.
            case source
            /// assets/** → reopen (media caches), no rebuild.
            case asset
            /// .swift-render/reviews/*.json → reload comments.
            case review
            /// .swift-render/knobs/*.json → setKnobs.
            case knobs
            /// Package.swift / swift-render.json → rebuild (and maybe re-resolve).
            case manifest
        }
        let kind: Kind
        /// Root-relative paths.
        let paths: [String]
    }

    let root: URL
    private let latency: TimeInterval
    private let handler: @Sendable ([Change]) -> Void
    private let queue = DispatchQueue(label: "studio.filewatcher")
    private var stream: FSEventStreamRef?
    private var pending: [Change.Kind: Set<String>] = [:]
    private var flush: DispatchWorkItem?
    /// Settable while running (an agent run raises it to 600 ms).
    var debounce: Duration {
        get { queue.sync { _debounce } }
        set { queue.sync { _debounce = newValue } }
    }
    private var _debounce: Duration

    init(root: URL, latency: TimeInterval = 0.1, debounce: Duration = .milliseconds(150),
         handler: @escaping @Sendable ([Change]) -> Void) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.latency = latency
        self._debounce = debounce
        self.handler = handler
    }

    deinit { stop() }

    func start() {
        guard stream == nil else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let arr = unsafeBitCast(paths, to: NSArray.self)
            var list: [String] = []
            for i in 0..<count { if let s = arr[i] as? String { list.append(s) } }
            me.received(list)
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                           | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)
        guard let s = FSEventStreamCreate(nil, callback, &ctx, [root.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
        queue.sync { flush?.cancel(); flush = nil; pending = [:] }
    }

    /// On `queue`.
    private func received(_ absolutePaths: [String]) {
        var any = false
        for p in absolutePaths {
            let rel = Self.relative(p, root: root.path)
            guard let rel, let kind = Self.classify(rel) else { continue }
            pending[kind, default: []].insert(rel)
            any = true
        }
        guard any else { return }
        flush?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.deliver() }
        flush = item
        let ms = Double(_debounce.components.seconds) * 1000 + Double(_debounce.components.attoseconds) / 1e15
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(ms)), execute: item)
    }

    private func deliver() {
        let changes = Self.coalesce(pending)
        pending = [:]
        flush = nil
        if !changes.isEmpty { handler(changes) }
    }

    // MARK: Pure helpers (tested)

    /// Root-relative path, or nil when outside the root. FSEvents reports resolved
    /// paths (/private/tmp…), so both sides are compared resolved.
    static func relative(_ path: String, root: String) -> String? {
        let r = root.hasSuffix("/") ? root : root + "/"
        if path.hasPrefix(r) { return String(path.dropFirst(r.count)) }
        let alt = r.hasPrefix("/private/") ? String(r.dropFirst("/private".count)) : "/private" + r
        if path.hasPrefix(alt) { return String(path.dropFirst(alt.count)) }
        return nil
    }

    static func classify(_ rel: String) -> Change.Kind? {
        let parts = rel.split(separator: "/").map(String.init)
        guard let name = parts.last, !parts.isEmpty else { return nil }
        // Build products, VCS, renders, editor droppings.
        if let first = parts.first, [".build", ".git", ".swiftpm", "out", "node_modules"].contains(first) { return nil }
        if name == ".DS_Store" || name.hasSuffix(".swp") || name.hasSuffix("~") || name.hasPrefix(".#")
            || name.hasSuffix(".lock") || name.hasPrefix(".") && parts.count == 1 { return nil }
        if parts.first == ".swift-render" {
            guard parts.count == 3, name.hasSuffix(".json") else { return nil }   // cache/, attachments/ ignored
            switch parts[1] {
            case "reviews": return .review
            case "knobs": return .knobs
            default: return nil
            }
        }
        if parts.count == 1, name == "Package.swift" || name == "Package.resolved" || name == "swift-render.json" {
            return .manifest
        }
        if parts.first == "assets" { return .asset }
        if parts.first == "Sources" || parts.first == "Plugins" { return .source }
        if name.hasSuffix(".swift") || name.hasSuffix(".metal") { return .source }
        return nil
    }

    /// Stable order: manifest, source, asset, knobs, review.
    static func coalesce(_ pending: [Change.Kind: Set<String>]) -> [Change] {
        let order: [Change.Kind] = [.manifest, .source, .asset, .knobs, .review]
        return order.compactMap { k in
            guard let paths = pending[k], !paths.isEmpty else { return nil }
            return Change(kind: k, paths: paths.sorted())
        }
    }
}
