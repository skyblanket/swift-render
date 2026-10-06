import Foundation

// MARK: - Props as an editable JSON tree
//
// The Props tab edits a scene's props JSON as a form. `JSONSerialization` would
// reorder keys and turn 120 into 120.0, so this keeps its own small JSON value:
// objects keep key order and numbers keep their literal text. `pretty` writes the
// same layout as the host's template (JSONEncoder .prettyPrinted), so a round trip
// through the form changes only what was edited.

indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    /// The literal as written ("120", "0.85", "1e-3").
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([JSONMember])

    var isContainer: Bool {
        switch self { case .array, .object: return true; default: return false }
    }

    var children: [(PropsPath.Component, JSONValue)] {
        switch self {
        case .array(let a): return a.enumerated().map { (.index($0.offset), $0.element) }
        case .object(let o): return o.map { (.key($0.key), $0.value) }
        default: return []
        }
    }

    var numberValue: Double? { if case .number(let s) = self { return Double(s) }; return nil }

    /// Short summary for a collapsed row: `[412]`, `{3}`, `"JETRAY"`.
    var summary: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let s): return s
        case .string(let s): return "\"\(s)\""
        case .array(let a): return "[\(a.count)]"
        case .object(let o): return "{\(o.count)}"
        }
    }
}

struct JSONMember: Equatable, Sendable {
    var key: String
    var value: JSONValue
}

/// A location in the tree: `stats.1.value`.
struct PropsPath: Hashable, Sendable, CustomStringConvertible {
    enum Component: Hashable, Sendable {
        case key(String)
        case index(Int)
    }
    var components: [Component] = []

    static let root = PropsPath()

    func appending(_ c: Component) -> PropsPath { PropsPath(components: components + [c]) }
    var parent: PropsPath? { components.isEmpty ? nil : PropsPath(components: Array(components.dropLast())) }
    var last: Component? { components.last }

    var description: String {
        components.map { c -> String in
            switch c { case .key(let k): return k; case .index(let i): return String(i) }
        }.joined(separator: ".")
    }

    /// Ancestors from the root down, excluding self.
    var ancestors: [PropsPath] {
        (0..<components.count).map { PropsPath(components: Array(components.prefix($0))) }
    }

    /// Parses a coding path as `DecodingError` prints it: "stats.Index 1.value" or "stats.1.value".
    init(codingPath: String) {
        components = codingPath.split(separator: ".", omittingEmptySubsequences: true).map { part in
            let s = part.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("Index "), let i = Int(s.dropFirst(6)) { return .index(i) }
            if let i = Int(s) { return .index(i) }
            return .key(s)
        }
    }

    init(components: [Component] = []) { self.components = components }
}

// MARK: - Parse

struct JSONParseError: Error, Equatable, CustomStringConvertible {
    var message: String
    var line: Int
    var column: Int
    var description: String { "line \(line), column \(column): \(message)" }
}

extension JSONValue {
    static func parse(_ text: String) throws -> JSONValue {
        var p = JSONParser(Array(text.utf8))
        p.skipSpace()
        let v = try p.value(depth: 0)
        p.skipSpace()
        guard p.atEnd else { throw p.error("unexpected text after the JSON value") }
        return v
    }
}

private struct JSONParser {
    let b: [UInt8]
    var i = 0
    init(_ bytes: [UInt8]) { b = bytes }

    var atEnd: Bool { i >= b.count }

    func error(_ message: String) -> JSONParseError {
        var line = 1, col = 1
        for k in 0..<min(i, b.count) {
            if b[k] == 0x0A { line += 1; col = 1 } else if b[k] & 0xC0 != 0x80 { col += 1 }
        }
        return JSONParseError(message: message, line: line, column: col)
    }

    mutating func skipSpace() {
        while i < b.count, [0x20, 0x09, 0x0A, 0x0D].contains(b[i]) { i += 1 }
    }

    mutating func expect(_ c: UInt8, _ what: String) throws {
        skipSpace()
        guard i < b.count, b[i] == c else { throw error("expected \(what)") }
        i += 1
    }

    mutating func value(depth: Int) throws -> JSONValue {
        guard depth < 256 else { throw error("nesting too deep") }
        skipSpace()
        guard i < b.count else { throw error("unexpected end of input") }
        switch b[i] {
        case UInt8(ascii: "{"):
            i += 1
            var members: [JSONMember] = []
            skipSpace()
            if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
            while true {
                skipSpace()
                guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw error("expected a \"key\"") }
                let key = try string()
                try expect(UInt8(ascii: ":"), "':' after key")
                members.append(JSONMember(key: key, value: try value(depth: depth + 1)))
                skipSpace()
                guard i < b.count else { throw error("unterminated object") }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
                throw error("expected ',' or '}'")
            }
        case UInt8(ascii: "["):
            i += 1
            var items: [JSONValue] = []
            skipSpace()
            if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            while true {
                items.append(try value(depth: depth + 1))
                skipSpace()
                guard i < b.count else { throw error("unterminated array") }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                throw error("expected ',' or ']'")
            }
        case UInt8(ascii: "\""):
            return .string(try string())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        default:
            return .number(try number())
        }
    }

    mutating func literal(_ word: String) throws {
        let w = Array(word.utf8)
        guard i + w.count <= b.count, Array(b[i..<i + w.count]) == w else { throw error("unexpected token") }
        i += w.count
    }

    mutating func number() throws -> String {
        let start = i
        if i < b.count, b[i] == UInt8(ascii: "-") { i += 1 }
        while i < b.count, (0x30...0x39).contains(b[i]) || [UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"),
                                                            UInt8(ascii: "+"), UInt8(ascii: "-")].contains(b[i]) { i += 1 }
        let text = String(decoding: b[start..<i], as: UTF8.self)
        guard !text.isEmpty, JSONValue.isNumberLiteral(text) else { i = start; throw error("unexpected token") }
        return text
    }

    mutating func string() throws -> String {
        i += 1                                     // opening quote
        var out = [UInt8]()
        while i < b.count {
            let c = b[i]
            if c == UInt8(ascii: "\"") { i += 1; return String(decoding: out, as: UTF8.self) }
            if c < 0x20 { throw error("control character in string") }
            if c == UInt8(ascii: "\\") {
                i += 1
                guard i < b.count else { break }
                switch b[i] {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try hex4()
                    if (0xD800...0xDBFF).contains(scalar), i + 2 < b.count,
                       b[i + 1] == UInt8(ascii: "\\"), b[i + 2] == UInt8(ascii: "u") {
                        i += 2
                        let low = try hex4()
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    }
                    out.append(contentsOf: Array(String(Character(Unicode.Scalar(scalar) ?? "\u{FFFD}")).utf8))
                default: throw error("bad escape")
                }
                i += 1
                continue
            }
            out.append(c)
            i += 1
        }
        throw error("unterminated string")
    }

    /// Reads the 4 hex digits after `\u`; leaves `i` on the last digit.
    mutating func hex4() throws -> UInt32 {
        guard i + 4 < b.count, let v = UInt32(String(decoding: b[(i + 1)...(i + 4)], as: UTF8.self), radix: 16) else {
            throw error("bad \\u escape")
        }
        i += 4
        return v
    }
}

// MARK: - Write

extension JSONValue {
    /// Strict JSON number grammar (no leading zeros, no "+", no bare ".").
    static func isNumberLiteral(_ s: String) -> Bool {
        s.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil
    }

    /// A number literal for `d` ("120", "0.85"); nil for NaN/∞, which JSON can't hold.
    static func numberLiteral(_ d: Double) -> String? {
        guard d.isFinite else { return nil }
        if d.rounded() == d, abs(d) < 1e15 { return String(Int64(d)) }
        return "\(d)"
    }

    /// JSONEncoder `.prettyPrinted` layout: two-space indent, `"key" : value`.
    var pretty: String {
        var out = ""
        write(into: &out, indent: 0)
        return out
    }

    private func write(into out: inout String, indent: Int) {
        let pad = String(repeating: "  ", count: indent + 1), close = String(repeating: "  ", count: indent)
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let s): out += s
        case .string(let s): out += Self.quote(s)
        case .array(let a):
            guard !a.isEmpty else { out += "[\n\n\(close)]"; return }
            out += "[\n"
            for (k, v) in a.enumerated() {
                out += pad
                v.write(into: &out, indent: indent + 1)
                out += k == a.count - 1 ? "\n" : ",\n"
            }
            out += close + "]"
        case .object(let o):
            guard !o.isEmpty else { out += "{\n\n\(close)}"; return }
            out += "{\n"
            for (k, m) in o.enumerated() {
                out += pad + Self.quote(m.key) + " : "
                m.value.write(into: &out, indent: indent + 1)
                out += k == o.count - 1 ? "\n" : ",\n"
            }
            out += close + "}"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }
}

// MARK: - Edit

extension JSONValue {
    subscript(path: PropsPath) -> JSONValue? {
        var v = self
        for c in path.components {
            switch (c, v) {
            case (.key(let k), .object(let o)):
                guard let m = o.first(where: { $0.key == k }) else { return nil }
                v = m.value
            case (.index(let i), .array(let a)):
                guard a.indices.contains(i) else { return nil }
                v = a[i]
            default: return nil
            }
        }
        return v
    }

    /// Replace the value at `path` (which must exist). Returns false when it doesn't.
    @discardableResult
    mutating func set(_ path: PropsPath, _ value: JSONValue) -> Bool {
        guard let first = path.components.first else { self = value; return true }
        let rest = PropsPath(components: Array(path.components.dropFirst()))
        switch (first, self) {
        case (.key(let k), .object(var o)):
            guard let i = o.firstIndex(where: { $0.key == k }), o[i].value.set(rest, value) else { return false }
            self = .object(o)
            return true
        case (.index(let i), .array(var a)):
            guard a.indices.contains(i), a[i].set(rest, value) else { return false }
            self = .array(a)
            return true
        default: return false
        }
    }

    /// Append a copy of the last element to the array at `path` (no-op when empty).
    @discardableResult
    mutating func appendClone(at path: PropsPath) -> Bool {
        guard case .array(var a)? = self[path], let last = a.last else { return false }
        a.append(last)
        return set(path, .array(a))
    }

    /// Remove an array element (`path` ends in an index).
    @discardableResult
    mutating func remove(at path: PropsPath) -> Bool {
        guard case .index(let i)? = path.last, let parent = path.parent,
              case .array(var a)? = self[parent], a.indices.contains(i) else { return false }
        a.remove(at: i)
        return set(parent, .array(a))
    }

    /// The deepest existing node on `path` (errors about a missing key land on its object).
    func nearestExisting(_ path: PropsPath) -> PropsPath {
        var p = path
        while self[p] == nil, let parent = p.parent { p = parent }
        return p
    }
}

// MARK: - Field kinds and rows

enum PropsFieldKind: Equatable {
    case bool, number, text, color, media, null, array, object

    static let mediaExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "webp", "tif", "tiff", "pdf", "svg",
                                               "mov", "mp4", "m4v", "wav", "m4a", "mp3", "aif", "aiff", "caf"]

    init(_ v: JSONValue) {
        switch v {
        case .null: self = .null
        case .bool: self = .bool
        case .number: self = .number
        case .array: self = .array
        case .object: self = .object
        case .string(let s):
            if s.range(of: #"^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$"#, options: .regularExpression) != nil { self = .color }
            else if !s.contains("\n"), let ext = s.split(separator: ".").last.map({ $0.lowercased() }),
                    s.contains("."), Self.mediaExtensions.contains(ext) { self = .media }
            else { self = .text }
        }
    }
}

/// One visible line of the form.
struct PropsRow: Identifiable, Equatable {
    var path: PropsPath
    var depth: Int
    var value: JSONValue
    var kind: PropsFieldKind
    var id: PropsPath { path }

    var label: String {
        switch path.last {
        case .key(let k): return k
        case .index(let i): return "\(i)"
        case nil: return "props"
        }
    }

    var isArrayElement: Bool { if case .index? = path.last { return true }; return false }
}

extension JSONValue {
    /// The form's rows: the root's children, and the children of every expanded container.
    func rows(expanded: Set<PropsPath>) -> [PropsRow] {
        var out: [PropsRow] = []
        func walk(_ v: JSONValue, _ path: PropsPath, _ depth: Int) {
            for (c, child) in v.children {
                let p = path.appending(c)
                out.append(PropsRow(path: p, depth: depth, value: child, kind: PropsFieldKind(child)))
                if child.isContainer, expanded.contains(p) { walk(child, p, depth + 1) }
            }
        }
        walk(self, .root, 0)
        return out
    }

    /// Containers to open by default: small ones near the top. A 400-sample array stays shut.
    func defaultExpanded(maxChildren: Int = 8, maxDepth: Int = 1) -> Set<PropsPath> {
        var out = Set<PropsPath>()
        func walk(_ v: JSONValue, _ path: PropsPath, _ depth: Int) {
            for (c, child) in v.children where child.isContainer {
                let p = path.appending(c)
                if depth < maxDepth, child.children.count <= maxChildren {
                    out.insert(p)
                    walk(child, p, depth + 1)
                }
            }
        }
        walk(self, .root, 0)
        return out
    }
}

// MARK: - Host errors → fields

/// A props problem the host reported, located in the tree when it names a coding path.
struct PropsIssue: Equatable {
    var message: String
    /// Where the decoder stopped; nil for syntax errors and messages without a path.
    var path: PropsPath?

    /// Reads the host's `badParams` text: "props: expected Double at stats.Index 1.value",
    /// "props: missing key 'unit' at stats.Index 0", "props: null for String at title".
    static func parse(_ text: String) -> PropsIssue {
        var s = text
        if let r = s.range(of: "props: ") { s = String(s[r.upperBound...]) }
        if s.hasPrefix("missing key '"), let close = s.dropFirst(13).firstIndex(of: "'") {
            let key = String(s[s.index(s.startIndex, offsetBy: 13)..<close])
            let at = s.range(of: " at ").map { String(s[$0.upperBound...]) } ?? ""
            return PropsIssue(message: "missing key “\(key)”", path: PropsPath(codingPath: at))
        }
        if s.hasPrefix("expected ") || s.hasPrefix("null for "), let r = s.range(of: " at ", options: .backwards) {
            var what = String(s[..<r.lowerBound])
            if what.hasPrefix("null for ") { what = "expected " + what.dropFirst(9) + ", got null" }
            return PropsIssue(message: what, path: PropsPath(codingPath: String(s[r.upperBound...])))
        }
        return PropsIssue(message: s, path: nil)
    }
}
