import CoreGraphics
import Foundation

// MARK: - Frame cache
//
// LRU of decoded frames keyed by (generation, frame, width bucket) with a byte budget.
// Generations change on open/setKnobs/setProps/host swap, so stale pixels can never
// be shown for a new build. Lookups for display take the widest cached copy of a
// frame, or the nearest earlier frame (what a viewer holds while waiting).
//
// Frames are held decoded (w×h×4 bytes). Keeping JPEG bytes and decoding at display
// time (~1 ms at 960×540) would fit ~50× more frames; see followups.

final class FrameCache: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        let generation: Int
        let frame: Int
        let widthBucket: Int
    }

    private final class Node {
        let key: Key
        let frame: DecodedFrame
        var prev: Node?
        var next: Node?
        init(_ key: Key, _ frame: DecodedFrame) { self.key = key; self.frame = frame }
    }

    private let lock = NSLock()
    private var map: [Key: Node] = [:]
    /// generation → frame → widths cached (fast "best width" and "nearest earlier").
    private var index: [Int: [Int: Set<Int>]] = [:]
    private var head: Node?     // most recent
    private var tail: Node?     // least recent
    private(set) var bytes = 0
    var budgetBytes: Int {
        didSet { lock.lock(); evict(); lock.unlock() }
    }

    init(budgetBytes: Int = 1 << 30) { self.budgetBytes = budgetBytes }

    /// Width bucket: 64-px steps so 959/960/961 share a slot.
    static func bucket(_ width: Int) -> Int { max(1, (width + 32) / 64) }

    var count: Int { lock.lock(); defer { lock.unlock() }; return map.count }

    func get(_ k: Key) -> DecodedFrame? {
        lock.lock(); defer { lock.unlock() }
        guard let n = map[k] else { return nil }
        touch(n)
        return n.frame
    }

    func put(_ k: Key, _ f: DecodedFrame) {
        lock.lock(); defer { lock.unlock() }
        if let old = map[k] { unlink(old); bytes -= old.frame.byteCost }
        let n = Node(k, f)
        map[k] = n
        index[k.generation, default: [:]][k.frame, default: []].insert(k.widthBucket)
        pushFront(n)
        bytes += f.byteCost
        evict()
    }

    func put(_ f: DecodedFrame, generation: Int) {
        put(Key(generation: generation, frame: f.index, widthBucket: Self.bucket(f.width)), f)
    }

    /// Widest cached copy of `frame`, optionally at least `minWidth` wide.
    func best(generation: Int, frame: Int, minWidth: Int = 0) -> DecodedFrame? {
        lock.lock(); defer { lock.unlock() }
        guard let widths = index[generation]?[frame], let w = widths.max() else { return nil }
        guard let n = map[Key(generation: generation, frame: frame, widthBucket: w)] else { return nil }
        if n.frame.width < minWidth { return nil }
        touch(n)
        return n.frame
    }

    /// The cached frame at or before `frame`, searching back at most `within` frames.
    func nearest(generation: Int, atOrBefore frame: Int, within: Int) -> DecodedFrame? {
        lock.lock()
        let frames = index[generation]
        lock.unlock()
        guard let frames else { return nil }
        var f = frame
        while f >= max(0, frame - within) {
            if frames[f] != nil { return best(generation: generation, frame: f) }
            f -= 1
        }
        return nil
    }

    func contains(generation: Int, frame: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return index[generation]?[frame]?.isEmpty == false
    }

    /// Contiguous cached spans in seconds (ruler cache bar). Gaps ≤ `tolerance` frames
    /// are bridged so 30 fps playback of a 60 fps scene shows as one span.
    func cachedRanges(generation: Int, fps: Int, tolerance: Int = 2) -> [ClosedRange<Double>] {
        lock.lock()
        let frames = index[generation].map { Array($0.keys).sorted() } ?? []
        lock.unlock()
        guard var start = frames.first else { return [] }
        var prev = start
        var out: [ClosedRange<Double>] = []
        let d = Double(max(1, fps))
        for f in frames.dropFirst() {
            if f - prev > tolerance {
                out.append(Double(start) / d...Double(prev + 1) / d)
                start = f
            }
            prev = f
        }
        out.append(Double(start) / d...Double(prev + 1) / d)
        return out
    }

    /// Drop every generation older than `generation`.
    func purge(below generation: Int) {
        lock.lock(); defer { lock.unlock() }
        for (k, n) in map where k.generation < generation {
            unlink(n); map[k] = nil; bytes -= n.frame.byteCost
        }
        index = index.filter { $0.key >= generation }
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        map = [:]; index = [:]; head = nil; tail = nil; bytes = 0
    }

    // MARK: LRU list (caller holds lock)

    private func touch(_ n: Node) {
        guard head !== n else { return }
        unlink(n); pushFront(n)
    }

    private func pushFront(_ n: Node) {
        n.prev = nil; n.next = head
        head?.prev = n
        head = n
        if tail == nil { tail = n }
    }

    private func unlink(_ n: Node) {
        n.prev?.next = n.next
        n.next?.prev = n.prev
        if head === n { head = n.next }
        if tail === n { tail = n.prev }
        n.prev = nil; n.next = nil
    }

    private func evict() {
        while bytes > budgetBytes, let victim = tail {
            unlink(victim)
            map[victim.key] = nil
            bytes -= victim.frame.byteCost
            let k = victim.key
            index[k.generation]?[k.frame]?.remove(k.widthBucket)
            if index[k.generation]?[k.frame]?.isEmpty == true { index[k.generation]?[k.frame] = nil }
        }
    }
}
