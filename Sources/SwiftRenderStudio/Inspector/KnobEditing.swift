import Foundation
import SwiftRenderKit

// MARK: - Knob values: coercion, formatting, colors
//
// Pure helpers behind the Knobs tab, kept free of SwiftUI so they're unit-tested.
// Values typed into fields, read from a hand-edited knobs file, or produced by a
// slider all go through `KnobCoercion` before reaching the host, so the file
// only ever holds what the engine's `Knob.*` readers accept.

enum KnobCoercion {
    /// `v` as a value of `kind`, or nil when it can't be one. Numbers accept numeric
    /// strings; bools accept 0/1 and yes/no/on/off; colors normalize to "#RRGGBB[AA]".
    static func coerce(_ v: KnobValue, to kind: KnobInfo.Kind) -> KnobValue? {
        switch (kind, v) {
        case (.double, .number(let d)): return d.isFinite ? .number(d) : nil
        case (.double, .string(let s)): return parseNumber(s).map(KnobValue.number)
        case (.double, .bool): return nil
        case (.bool, .bool): return v
        case (.bool, .number(let d)): return d == 0 || d == 1 ? .bool(d == 1) : nil
        case (.bool, .string(let s)): return parseBool(s).map(KnobValue.bool)
        case (.text, .string): return v
        case (.text, .number(let d)): return .string(format(d))
        case (.text, .bool(let b)): return .string(b ? "true" : "false")
        case (.color, .string(let s)): return normalizeHex(s).map(KnobValue.string)
        case (.color, _): return nil
        }
    }

    /// What a user typed into a knob's field.
    static func parse(_ text: String, kind: KnobInfo.Kind) -> KnobValue? {
        coerce(.string(text), to: kind)
    }

    /// Locale-independent: "0.5", " .5 ", "1e-3", "-2" (a comma decimal is accepted too).
    static func parseNumber(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty, let d = Double(t), d.isFinite else { return nil }
        return d
    }

    static func parseBool(_ s: String) -> Bool? {
        switch s.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: return nil
        }
    }

    // MARK: Colors

    /// "#RGB", "RRGGBB", "#rrggbbaa"… → "#RRGGBB" or "#RRGGBBAA" (alpha kept only when < FF).
    static func normalizeHex(_ s: String) -> String? {
        var h = s.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.allSatisfy(\.isHexDigit) else { return nil }
        switch h.count {
        case 3, 4: h = h.map { "\($0)\($0)" }.joined()
        case 6, 8: break
        default: return nil
        }
        h = h.uppercased()
        if h.count == 8, h.hasSuffix("FF") { h.removeLast(2) }
        return "#" + h
    }

    /// sRGB components 0…1 of a hex color.
    static func rgba(_ hex: String) -> (r: Double, g: Double, b: Double, a: Double)? {
        guard let n = normalizeHex(hex), let v = UInt64(n.dropFirst(), radix: 16) else { return nil }
        if n.count == 7 {
            return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255, 1)
        }
        return (Double((v >> 24) & 0xFF) / 255, Double((v >> 16) & 0xFF) / 255,
                Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    /// sRGB components → "#RRGGBB", or "#RRGGBBAA" when not opaque.
    static func hex(r: Double, g: Double, b: Double, a: Double = 1) -> String {
        func byte(_ x: Double) -> Int { Int((min(1, max(0, x)) * 255).rounded()) }
        let rgb = String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
        return byte(a) == 255 ? rgb : rgb + String(format: "%02X", byte(a))
    }

    // MARK: Numbers

    /// A slider step of 1, 2 or 5 × 10ⁿ giving roughly 100 stops over `range`.
    static func step(for range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0, span.isFinite else { return 0.01 }
        let raw = span / 100
        let mag = pow(10, floor(log10(raw)))
        let n = raw / mag
        return (n <= 1 ? 1 : n <= 2 ? 2 : n <= 5 ? 5 : 10) * mag
    }

    /// `v` rounded to a multiple of `step`, without binary noise (0.30000000000000004 → 0.3),
    /// so knobs files stay readable.
    static func snap(_ v: Double, step: Double) -> Double {
        guard step > 0, v.isFinite else { return v }
        let snapped = (v / step).rounded() * step
        return Double(String(format: "%.\(decimals(for: step))f", snapped)) ?? snapped
    }

    /// Decimal places that show a value at `step` resolution (0.05 → 2, 5 → 0).
    static func decimals(for step: Double) -> Int {
        guard step > 0, step.isFinite else { return 2 }
        return max(0, min(6, Int(ceil(-log10(step) - 1e-9))))
    }

    /// Shortest faithful text for a number: "1", "0.4", "-2.25" (no trailing zeros).
    static func format(_ d: Double) -> String {
        if d.rounded() == d, abs(d) < 1e15 { return String(Int64(d)) }
        var s = String(format: "%.6f", d)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// One-line display of any value (lists, tooltips).
    static func display(_ v: KnobValue) -> String {
        switch v {
        case .number(let d): return format(d)
        case .bool(let b): return b ? "on" : "off"
        case .string(let s): return s
        }
    }

    // MARK: Override sets

    /// The live set worth saving: values coerced to their knob's kind, and overrides
    /// equal to the source default dropped (they don't change a pixel). Keys of knobs
    /// the probe hasn't seen are kept as they are.
    static func normalized(_ values: [String: KnobValue], knobs: [KnobInfo]) -> [String: KnobValue] {
        let byKey = Dictionary(knobs.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [String: KnobValue] = [:]
        for (k, v) in values {
            guard let info = byKey[k] else { out[k] = v; continue }
            guard let c = coerce(v, to: info.kind) else { continue }
            if c != info.defaultValue { out[k] = c }
        }
        return out
    }
}

// MARK: - Knobs the probe hasn't reached

/// Knob declarations found by scanning source text. The probe only sees knobs a
/// render actually reads; one behind `if Knob.bool("debug", false)` stays hidden
/// until that branch runs, so the tab lists these as "not reached yet".
struct DeclaredKnob: Equatable, Sendable {
    var key: String
    var kind: KnobInfo.Kind
    var line: Int
}

enum KnobSourceScan {
    private static let pattern = try! NSRegularExpression(pattern: #"Knob\.(double|bool|text|color)\(\s*"((?:[^"\\]|\\.)+)""#)

    /// Every `Knob.<kind>("key"` in `source`, first declaration of each key.
    static func declarations(in source: String) -> [DeclaredKnob] {
        var out: [DeclaredKnob] = []
        var seen = Set<String>()
        var line = 1, scanned = source.startIndex
        let ns = source as NSString
        for m in pattern.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            guard let r = Range(m.range, in: source),
                  let kind = KnobInfo.Kind(rawValue: ns.substring(with: m.range(at: 1))) else { continue }
            line += source[scanned..<r.lowerBound].reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
            scanned = r.lowerBound
            let key = ns.substring(with: m.range(at: 2))
            if seen.insert(key).inserted { out.append(DeclaredKnob(key: key, kind: kind, line: line)) }
        }
        return out
    }

    /// Declarations in `source` that aren't in `known`.
    static func unreached(in source: String, known: [KnobInfo]) -> [DeclaredKnob] {
        let keys = Set(known.map(\.key))
        return declarations(in: source).filter { !keys.contains($0.key) }
    }
}

// MARK: - Live sending

/// Paces knob changes to the host. A slider fires on every mouse move; the host
/// should see at most one `setKnobs` per `interval` while dragging, never more than
/// one in flight, and always the newest values. The release (`dragging: false`,
/// which re-probes) is never dropped or delayed by the interval.
@MainActor
final class KnobSender {
    typealias Send = @MainActor (_ values: [String: KnobValue], _ dragging: Bool) async -> Void

    let interval: Double
    private let send: Send
    private let now: () -> Double
    private let sleep: (Double) async -> Void
    private var pending: (values: [String: KnobValue], dragging: Bool)?
    private var inFlight = false
    private var timerArmed = false
    private var lastSend = -Double.infinity
    /// Requests actually sent (tests, diagnostics).
    private(set) var sentCount = 0

    init(interval: Double = 1.0 / 30, now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
         send: @escaping Send) {
        self.interval = interval; self.now = now; self.sleep = sleep; self.send = send
    }

    /// True while a request is out or queued.
    var isBusy: Bool { inFlight || pending != nil }

    /// Queue the complete override set. Mid-drag submissions replace each other;
    /// a release replaces any queued drag and goes out as soon as nothing is in flight.
    func submit(_ values: [String: KnobValue], dragging: Bool) {
        if let p = pending, !p.dragging, dragging {
            pending = (values, false)      // a release is queued: keep its re-probe
        } else {
            pending = (values, dragging)
        }
        pump()
    }

    /// Resolves when everything submitted so far has been sent and answered.
    func drain() async {
        while isBusy { await sleep(interval / 4) }
    }

    private func pump() {
        guard !inFlight, let p = pending else { return }
        let wait = lastSend + interval - now()
        if p.dragging, wait > 0 {
            guard !timerArmed else { return }
            timerArmed = true
            Task { @MainActor in
                await sleep(wait)
                timerArmed = false
                pump()
            }
            return
        }
        pending = nil
        inFlight = true
        lastSend = now()
        sentCount += 1
        Task { @MainActor in
            await send(p.values, p.dragging)
            inFlight = false
            pump()
        }
    }
}
