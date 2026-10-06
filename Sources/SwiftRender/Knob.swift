import SwiftUI
import SwiftRenderKit

// MARK: - Knobs
//
// Live-tunable constants. A scene reads `Knob.double("title.delay", 0.4, in: 0...2)`
// instead of a bare literal; Studio shows it as a slider and the value can be
// overridden without a rebuild. Overrides live in `.swift-render/knobs/<Scene>.json`
// and are loaded once before a render, so every frame is still a pure function
// of (t, overrides) — determinism holds.
//
// Read knobs inside `body` (not in a `static let`), or the first value sticks.
//
// STUB CONTRACT — signatures are fixed; the engine work fills in registration
// with the probe collector (see Introspection.swift).

public enum Knob {
    public static func double(_ key: String, _ value: Double, in range: ClosedRange<Double>? = nil,
                              file: String = #filePath, line: Int = #line) -> Double {
        KnobStore.shared.declare(KnobInfo(key: key, kind: .double, defaultValue: .number(value), value: .number(value),
                                          min: range?.lowerBound, max: range?.upperBound,
                                          source: SourceLocation(file: file, line: line)))
        return KnobStore.shared.override(key)?.doubleValue ?? value
    }

    public static func bool(_ key: String, _ value: Bool,
                            file: String = #filePath, line: Int = #line) -> Bool {
        KnobStore.shared.declare(KnobInfo(key: key, kind: .bool, defaultValue: .bool(value), value: .bool(value),
                                          source: SourceLocation(file: file, line: line)))
        return KnobStore.shared.override(key)?.boolValue ?? value
    }

    public static func text(_ key: String, _ value: String,
                            file: String = #filePath, line: Int = #line) -> String {
        KnobStore.shared.declare(KnobInfo(key: key, kind: .text, defaultValue: .string(value), value: .string(value),
                                          source: SourceLocation(file: file, line: line)))
        return KnobStore.shared.override(key)?.stringValue ?? value
    }

    /// Colors are stored as "#RRGGBB" / "#RRGGBBAA".
    public static func color(_ key: String, _ hex: String,
                             file: String = #filePath, line: Int = #line) -> Color {
        KnobStore.shared.declare(KnobInfo(key: key, kind: .color, defaultValue: .string(hex), value: .string(hex),
                                          source: SourceLocation(file: file, line: line)))
        return Color(rgbHex: KnobStore.shared.override(key)?.stringValue ?? hex) ?? Color(rgbHex: hex) ?? .white
    }
}

/// Process-wide knob overrides + declarations seen while probing. Thread-safe.
public final class KnobStore: @unchecked Sendable {
    public static let shared = KnobStore()

    private let lock = NSLock()
    private var overrides: [String: KnobValue] = [:]
    private var declared: [String: KnobInfo] = [:]
    private var recording = false

    /// Replace all overrides (e.g. loaded from `.swift-render/knobs/<Scene>.json`).
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

    func override(_ key: String) -> KnobValue? {
        lock.lock(); defer { lock.unlock() }; return overrides[key]
    }

    func declare(_ info: KnobInfo) {
        lock.lock(); defer { lock.unlock() }
        guard recording, declared[info.key] == nil else { return }
        var i = info
        if let o = overrides[info.key] { i.value = o }
        declared[info.key] = i
    }

    /// Start collecting declarations (used by SceneProbe).
    public func beginRecording() { lock.lock(); declared = [:]; recording = true; lock.unlock() }

    /// Stop collecting and return declarations sorted by key.
    public func endRecording() -> [KnobInfo] {
        lock.lock(); defer { lock.unlock() }
        recording = false
        return declared.values.sorted { $0.key < $1.key }
    }
}

public extension Color {
    /// "#RRGGBB" or "#RRGGBBAA" (leading # optional). nil when malformed.
    init?(rgbHex hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
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
