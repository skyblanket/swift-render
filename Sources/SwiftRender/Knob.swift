import SwiftUI
import SwiftRenderKit

// MARK: - Knobs
//
// Live-tunable constants. A scene reads `Knob.double("title.delay", 0.4, in: 0...2)`
// instead of a bare literal; Studio shows it as a slider and the value can be
// overridden without a rebuild. Overrides live in `.swift-render/knobs/<Scene>.json`
// and are loaded once before a render, so every frame is still a pure function
// of (t, overrides) — determinism holds. With no override a knob returns its
// literal unchanged, so adding knobs never moves a pixel.
//
// Read knobs inside `body` or `soundtrack` (not in a `static let`), or the first
// value sticks for the life of the process.

public enum Knob {
    /// A number. `range` is the slider's range in Studio, not a clamp.
    public static func double(_ key: String, _ value: Double, in range: ClosedRange<Double>? = nil,
                              file: String = #filePath, line: Int = #line) -> Double {
        let o = KnobStore.shared.read(key) { o in
            KnobInfo(key: key, kind: .double, defaultValue: .number(value),
                     value: o?.doubleValue.map { .number($0) } ?? .number(value),
                     min: range?.lowerBound, max: range?.upperBound,
                     source: SourceLocation(file: file, line: line))
        }
        return o?.doubleValue ?? value
    }

    public static func bool(_ key: String, _ value: Bool,
                            file: String = #filePath, line: Int = #line) -> Bool {
        let o = KnobStore.shared.read(key) { o in
            KnobInfo(key: key, kind: .bool, defaultValue: .bool(value),
                     value: o?.boolValue.map { .bool($0) } ?? .bool(value),
                     source: SourceLocation(file: file, line: line))
        }
        return o?.boolValue ?? value
    }

    public static func text(_ key: String, _ value: String,
                            file: String = #filePath, line: Int = #line) -> String {
        let o = KnobStore.shared.read(key) { o in
            KnobInfo(key: key, kind: .text, defaultValue: .string(value),
                     value: o?.stringValue.map { .string($0) } ?? .string(value),
                     source: SourceLocation(file: file, line: line))
        }
        return o?.stringValue ?? value
    }

    /// Colors are stored as "#RRGGBB" / "#RRGGBBAA". A malformed override falls back to `hex`.
    public static func color(_ key: String, _ hex: String,
                             file: String = #filePath, line: Int = #line) -> Color {
        let o = KnobStore.shared.read(key) { o in
            let valid = o?.stringValue.flatMap { Color(rgbHex: $0) == nil ? nil : $0 }
            return KnobInfo(key: key, kind: .color, defaultValue: .string(hex), value: .string(valid ?? hex),
                            source: SourceLocation(file: file, line: line))
        }
        return o?.stringValue.flatMap { Color(rgbHex: $0) } ?? Color(rgbHex: hex) ?? .white
    }
}

/// Process-wide knob overrides, plus the declarations seen while recording
/// (`SceneProbe.probe` records). Thread-safe: `soundtrack` reads knobs off-main.
public final class KnobStore: @unchecked Sendable {
    public static let shared = KnobStore()

    private let lock = NSLock()
    private var overrides: [String: KnobValue] = [:]
    /// One table per open `beginRecording()`; nested recordings each see every declaration.
    private var recordings: [[String: KnobInfo]] = []

    /// Replace all overrides (e.g. loaded from `.swift-render/knobs/<Scene>.json`).
    /// Set between frames: a frame rendered while values change may mix old and new.
    public func set(_ values: [String: KnobValue]) {
        lock.lock(); overrides = values; lock.unlock()
    }

    public var values: [String: KnobValue] {
        lock.lock(); defer { lock.unlock() }; return overrides
    }

    /// Load the project's knob file for `scene` (no file → no overrides).
    public func load(scene: String, project: Project?) {
        guard let project else { set([:]); return }
        set(KnobFile.load(project.knobsURL(scene: scene)))
    }

    /// The override for `key`, if any. While recording, also declares the knob;
    /// `declaration` gets the override so the declared value can show it.
    /// One lock per read; the first declaration of a key wins.
    func read(_ key: String, declaration: (KnobValue?) -> KnobInfo) -> KnobValue? {
        lock.lock(); defer { lock.unlock() }
        let o = overrides[key]
        if !recordings.isEmpty {
            let info = declaration(o)
            for i in recordings.indices where recordings[i][key] == nil { recordings[i][key] = info }
        }
        return o
    }

    /// Start collecting declarations. Pairs with `endRecording()`; pairs may nest.
    public func beginRecording() { lock.lock(); recordings.append([:]); lock.unlock() }

    /// Stop the innermost recording and return its declarations sorted by key.
    public func endRecording() -> [KnobInfo] {
        lock.lock(); defer { lock.unlock() }
        guard let declared = recordings.popLast() else { return [] }
        return declared.values.sorted { $0.key < $1.key }
    }
}

public extension Color {
    /// "#RRGGBB" or "#RRGGBBAA" (leading # optional), sRGB. nil when malformed.
    init?(rgbHex hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, s.allSatisfy(\.isHexDigit), let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: Double
        if s.count == 6 {
            r = Double((v >> 16) & 0xFF) / 255; g = Double((v >> 8) & 0xFF) / 255; b = Double(v & 0xFF) / 255; a = 1
        } else {
            r = Double((v >> 24) & 0xFF) / 255; g = Double((v >> 16) & 0xFF) / 255
            b = Double((v >> 8) & 0xFF) / 255; a = Double(v & 0xFF) / 255
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
