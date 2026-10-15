import SwiftRenderKit
import SwiftUI

// MARK: - SwiftHighlighter

/// A zero-dependency Swift lexer good enough for on-screen snippets: comments,
/// strings (incl. multi-line and raw), numbers, keywords, `@attributes`,
/// `#directives`, capitalized types and `call(` sites.
public enum SwiftHighlighter {
    /// What a token is, which picks its color.
    public enum Kind: Sendable, Equatable { case plain, keyword, type, call, string, number, comment, attribute, punctuation }

    /// A run of source text and its kind.
    public struct Token: Sendable, Equatable {
        /// The exact source text.
        public var text: String
        /// The token's category.
        public var kind: Kind
        /// Creates a token.
        public init(_ text: String, _ kind: Kind) { self.text = text; self.kind = kind }
    }

    static let keywords: Set<String> = [
        "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue",
        "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate",
        "for", "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "let", "mutating", "nil",
        "nonisolated", "open", "operator", "override", "private", "protocol", "public", "repeat", "rethrows",
        "return", "self", "Self", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws",
        "true", "try", "typealias", "var", "where", "while", "lazy", "weak", "final", "required", "convenience",
        "get", "set", "willSet", "didSet", "consuming", "borrowing", "sending",
    ]

    /// Tokens per line. Joining a line's token texts reproduces the line exactly.
    public static func tokenize(_ source: String) -> [[Token]] {
        var out: [[Token]] = []
        var inBlockComment = false
        var inMultiString = false
        for line in source.components(separatedBy: "\n") {
            var toks: [Token] = []
            let chars = Array(line)
            var i = 0
            func emit(_ s: String, _ k: Kind) {
                if let last = toks.last, last.kind == k, k != .call, k != .type, k != .keyword {
                    toks[toks.count - 1].text += s
                } else { toks.append(Token(s, k)) }
            }
            while i < chars.count {
                let c = chars[i]
                let rest = String(chars[i...])
                if inBlockComment {
                    if let r = rest.range(of: "*/") {
                        let n = rest.distance(from: rest.startIndex, to: r.upperBound)
                        emit(String(chars[i..<i + n]), .comment); i += n; inBlockComment = false
                    } else { emit(rest, .comment); i = chars.count }
                    continue
                }
                if inMultiString {
                    if let r = rest.range(of: "\"\"\"") {
                        let n = rest.distance(from: rest.startIndex, to: r.upperBound)
                        emit(String(chars[i..<i + n]), .string); i += n; inMultiString = false
                    } else { emit(rest, .string); i = chars.count }
                    continue
                }
                if rest.hasPrefix("//") { emit(rest, .comment); break }
                if rest.hasPrefix("/*") { inBlockComment = true; emit("/*", .comment); i += 2; continue }
                if rest.hasPrefix("\"\"\"") { inMultiString = true; emit("\"\"\"", .string); i += 3; continue }
                if c == "\"" || (c == "#" && i + 1 < chars.count && chars[i + 1] == "\"") {
                    // single-line string (raw strings: #"…"#)
                    let raw = c == "#"
                    var j = i + (raw ? 2 : 1)
                    while j < chars.count {
                        if chars[j] == "\\" && !raw { j += 2; continue }
                        if chars[j] == "\"" { j += 1; if raw && j < chars.count && chars[j] == "#" { j += 1 }; break }
                        j += 1
                    }
                    j = min(j, chars.count)
                    emit(String(chars[i..<j]), .string); i = j; continue
                }
                if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber && (i == 0 || !chars[i - 1].isLetter)) {
                    var j = i
                    while j < chars.count, chars[j].isHexDigit || chars[j] == "." || chars[j] == "_" || chars[j] == "x" { j += 1 }
                    emit(String(chars[i..<j]), .number); i = j; continue
                }
                if c == "@" || (c == "#" && i + 1 < chars.count && chars[i + 1].isLetter) {
                    var j = i + 1
                    while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                    emit(String(chars[i..<j]), .attribute); i = j; continue
                }
                if c.isLetter || c == "_" {
                    var j = i
                    while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                    let word = String(chars[i..<j])
                    let afterDot = i > 0 && chars[i - 1] == "."
                    let nextIsParen = j < chars.count && (chars[j] == "(" || chars[j] == "{")
                    let kind: Kind
                    if keywords.contains(word) && !afterDot { kind = .keyword }
                    else if word.first!.isUppercase { kind = .type }
                    else if nextIsParen || afterDot { kind = .call }
                    else { kind = .plain }
                    emit(word, kind); i = j; continue
                }
                if "{}()[]<>,:;.=+-*/!?&|%^~".contains(c) { emit(String(c), .punctuation); i += 1; continue }
                emit(String(c), .plain); i += 1
            }
            out.append(toks)
        }
        return out
    }
}

/// Syntax colors for `CodeReveal`.
public struct CodePalette: Sendable {
    /// Color for each token kind.
    public var plain, keyword, type, call, string, number, comment, attribute, punctuation: Color
    /// Editor window fill.
    public var background: Color

    /// Creates a palette from one color per token kind plus the background.
    public init(plain: Color, keyword: Color, type: Color, call: Color, string: Color, number: Color,
                comment: Color, attribute: Color, punctuation: Color, background: Color) {
        self.plain = plain; self.keyword = keyword; self.type = type; self.call = call; self.string = string
        self.number = number; self.comment = comment; self.attribute = attribute; self.punctuation = punctuation
        self.background = background
    }

    /// Close to Xcode's Default (Dark).
    public static let xcodeDark = CodePalette(
        plain: Color(white: 0.92), keyword: Color(rgbHex: "#FF7AB2")!, type: Color(rgbHex: "#DABAFF")!,
        call: Color(rgbHex: "#67B7A4")!, string: Color(rgbHex: "#FF8170")!, number: Color(rgbHex: "#D9C97C")!,
        comment: Color(rgbHex: "#7F8C98")!, attribute: Color(rgbHex: "#FD8F3F")!, punctuation: Color(white: 0.68),
        background: Color(rgbHex: "#1F1F24")!)

    /// White ramp with the theme accent on keywords — calmer, on-brand.
    public static func monoAccent(_ accent: Color) -> CodePalette {
        CodePalette(plain: Color(white: 0.9), keyword: accent, type: .white, call: Color(white: 0.78),
                    string: Color(white: 0.62), number: accent, comment: Color(white: 0.42), attribute: accent,
                    punctuation: Color(white: 0.55), background: Color(white: 0.08))
    }

    func color(_ k: SwiftHighlighter.Kind) -> Color {
        switch k {
        case .plain: return plain
        case .keyword: return keyword
        case .type: return type
        case .call: return call
        case .string: return string
        case .number: return number
        case .comment: return comment
        case .attribute: return attribute
        case .punctuation: return punctuation
        }
    }
}

// MARK: - CodeReveal

/// A highlighted snippet in an editor window, revealed line by line or typed.
/// Lines outside `focus` dim once the reveal finishes.
public struct CodeReveal: View {
    /// How the snippet appears: typed at `cps` characters per second, line by line every `step` seconds, or all at once.
    public enum Mode: Sendable, Equatable {
        case typed(cps: Double = 42)
        case lines(step: Double = 0.09)
        case instant
    }

    var code: String
    var language: LaunchProps.CodeLanguage
    var t: Double
    var start: Double
    var mode: Mode
    var focus: Set<Int>
    var fontSize: CGFloat?
    var palette: CodePalette
    var title: String?
    var lineNumbers: Bool
    var maxWidth: CGFloat?
    var maxHeight: CGFloat?
    @Environment(\.launchTheme) private var theme
    @Environment(\.renderContext) private var ctx

    /// Non-Swift code is drawn in the plain color. `focus` lists the lines (1-based) left undimmed; `fontSize` nil fits the window.
    public init(_ code: String, language: LaunchProps.CodeLanguage = .swift, at t: Double, start: Double = 0.2,
                mode: Mode = .lines(), focus: [Int]? = nil, fontSize: CGFloat? = nil,
                palette: CodePalette = .xcodeDark, title: String? = nil, lineNumbers: Bool = true,
                maxWidth: CGFloat? = nil, maxHeight: CGFloat? = nil) {
        self.code = code; self.language = language; self.t = t; self.start = start; self.mode = mode
        self.focus = Set(focus ?? []); self.fontSize = fontSize; self.palette = palette; self.title = title
        self.lineNumbers = lineNumbers; self.maxWidth = maxWidth; self.maxHeight = maxHeight
    }

    /// When each line starts appearing (the score ticks here).
    public static func lineTimes(_ code: String, mode: Mode, start: Double) -> [Double] {
        let lines = code.components(separatedBy: "\n")
        switch mode {
        case .instant: return lines.map { _ in start }
        case .lines(let step): return lines.indices.map { start + Double($0) * step }
        case .typed(let cps):
            var t = start, out: [Double] = []
            for l in lines { out.append(t); t += Double(l.count + 1) / cps }
            return out
        }
    }

    /// When the whole snippet is in.
    public static func revealEnd(_ code: String, mode: Mode, start: Double) -> Double {
        switch mode {
        case .instant: return start
        case .lines(let step): return start + Double(code.components(separatedBy: "\n").count) * step + 0.3
        case .typed(let cps): return start + Double(code.count) / cps
        }
    }

    /// The editor window, with font size fitted to the width and height available.
    public var body: some View {
        let L = LaunchLayout(ctx)
        let lines = language == .swift ? SwiftHighlighter.tokenize(code)
            : code.components(separatedBy: "\n").map { [SwiftHighlighter.Token($0, .plain)] }
        let cols = max(20, code.components(separatedBy: "\n").map(\.count).max() ?? 20)
        let width = maxWidth ?? L.width
        let gutter: CGFloat = lineNumbers ? 3.2 : 0
        let fitted = (width - 96 * L.type) / (CGFloat(cols) + gutter) / 0.61
        // Height too: a line is ~1.2 em of text + 0.5 em spacing; the title bar and padding are fixed.
        let rows = CGFloat(lines.count)
        let chrome: CGFloat = 110 * L.type + 1     // title bar 54 + padding 2 × 28 + hairline
        let budget: CGFloat = maxHeight ?? .infinity
        let fittedHeight: CGFloat = (budget - chrome) / (rows * 1.7 - 0.5)
        let fs = min(fontSize ?? 30 * L.type, fitted, fittedHeight)
        let times = Self.lineTimes(code, mode: mode, start: start)
        let end = Self.revealEnd(code, mode: mode, start: start)
        let dim = focus.isEmpty ? 0 : Ease.easeInOut(Ease.clip(t, end + 0.3, end + 0.9))

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9 * L.type) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.white.opacity(0.18)).frame(width: 13 * L.type, height: 13 * L.type) }
                if let title {
                    Text(title).font(theme.text(17 * L.type, .medium)).foregroundStyle(Color.white.opacity(0.55))
                        .padding(.leading, 18 * L.type)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24 * L.type).frame(height: 54 * L.type)
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
            VStack(alignment: .leading, spacing: fs * 0.5) {
                ForEach(Array(lines.enumerated()), id: \.offset) { i, toks in
                    let appear = lineAppear(i, times)
                    let bright = focus.isEmpty || focus.contains(i + 1) ? 1 : 1 - 0.65 * dim
                    HStack(alignment: .firstTextBaseline, spacing: fs * 1.1) {
                        if lineNumbers {
                            Text("\(i + 1)").font(.system(size: fs * 0.82, weight: .regular, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.25))
                                .frame(width: fs * 1.3, alignment: .trailing)
                        }
                        lineText(toks, i, times, fs)
                    }
                    .opacity(appear * bright)
                    .offset(x: (1 - appear) * -14)
                }
            }
            .padding(.horizontal, 30 * L.type).padding(.vertical, 28 * L.type)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 24 * L.type, style: .continuous).fill(palette.background))
        .overlay(RoundedRectangle(cornerRadius: 24 * L.type, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(theme.isDark ? 0.6 : 0.2), radius: 40, y: 24)
    }

    private func lineAppear(_ i: Int, _ times: [Double]) -> Double {
        switch mode {
        case .instant: return 1
        case .lines: return Ease.easeOut(Ease.clip(t, times[i], times[i] + 0.28))
        case .typed: return t >= times[i] ? 1 : 0
        }
    }

    private func lineText(_ toks: [SwiftHighlighter.Token], _ i: Int, _ times: [Double], _ fs: CGFloat) -> Text {
        var shown = Int.max
        var caret = false
        if case .typed(let cps) = mode {
            shown = max(0, Int((t - times[i]) * cps))
            let lineLen = toks.reduce(0) { $0 + $1.text.count }
            let next = i + 1 < times.count ? times[i + 1] : .infinity
            caret = t >= times[i] && t < next && shown <= lineLen
                || (i == times.count - 1 && t >= times[i] && Int(t * 2) % 2 == 0)
        }
        var out = Text("")
        var used = 0
        for tok in toks {
            guard used < shown else { break }
            let take = min(tok.text.count, shown - used)
            let piece = String(tok.text.prefix(take))
            var txt = Text(piece).foregroundColor(palette.color(tok.kind))
            if tok.kind == .keyword { txt = txt.fontWeight(.semibold) }
            out = out + txt
            used += take
        }
        if caret { out = out + Text("▍").foregroundColor(theme.accent) }
        if toks.isEmpty { out = out + Text(" ") }
        return out.font(.system(size: fs, weight: .regular, design: .monospaced))
    }
}

// MARK: - TerminalCard

/// A terminal window: `$` prompt in the accent, commands typed with a solid caret,
/// output lines appearing as the command "finishes".
public struct TerminalCard: View {
    /// One line of the transcript and when it appears.
    public struct Line: Sendable, Equatable {
        /// How the line is drawn: typed command, plain output, success, failure or comment.
        public enum Kind: Sendable { case command, output, success, failure, comment }
        /// The line's text (without the prompt).
        public var text: String
        /// How the line is drawn.
        public var kind: Kind
        /// When the line starts (a command starts typing; output appears).
        public var at: Double
        /// Creates a line; `kind` defaults to output.
        public init(_ text: String, _ kind: Kind = .output, at: Double) { self.text = text; self.kind = kind; self.at = at }
    }

    var lines: [Line]
    var t: Double
    var title: String?
    var cps: Double
    var prompt: String
    var width: CGFloat?
    var fontSize: CGFloat
    @Environment(\.launchTheme) private var theme
    @Environment(\.renderContext) private var ctx

    /// `cps` is the typing speed for commands; `width` nil picks a width from the canvas.
    public init(_ lines: [Line], at t: Double, title: String? = nil, cps: Double = 30, prompt: String = "$ ",
                width: CGFloat? = nil, fontSize: CGFloat = 30) {
        self.lines = lines; self.t = t; self.title = title; self.cps = cps; self.prompt = prompt
        self.width = width; self.fontSize = fontSize
    }

    /// Times a shell transcript: lines starting with "$ " are typed at `cps`, the rest
    /// print 0.3 s after the command before them finishes (`LaunchTerminal.schedule`).
    public static func session(_ transcript: [String], start: Double = 0.3, cps: Double = 30) -> [Line] {
        LaunchTerminal.schedule(transcript, start: start, cps: cps).map { l in
            let kind: Line.Kind
            switch l.kind {
            case .command: kind = .command
            case .output: kind = .output
            case .success: kind = .success
            case .failure: kind = .failure
            case .comment: kind = .comment
            }
            return Line(l.text, kind, at: l.at)
        }
    }

    /// Keystroke times for the score (every `every`th character).
    public static func keystrokeTimes(_ lines: [Line], cps: Double, every: Int = 2) -> [Double] {
        lines.filter { $0.kind == .command }.flatMap { l in
            stride(from: 0, to: l.text.count, by: max(1, every)).map { l.at + Double($0) / cps }
        }
    }

    /// Columns a line takes (a command's prompt and caret included).
    static func columns(_ line: Line, prompt: String) -> Int {
        line.kind == .command ? prompt.count + line.text.count + 1 : line.text.count
    }

    /// The font size that fits the longest line in a card `width` wide: at most `fontSize`, never
    /// under `floor` (a line still too long then wraps). SF Mono advances 0.6 em; 0.62 leaves slack.
    public static func fittedFontSize(_ lines: [Line], prompt: String, width: CGFloat, padding: CGFloat,
                                      fontSize: CGFloat, floor: CGFloat) -> CGFloat {
        let cols = max(20, lines.map { columns($0, prompt: prompt) }.max() ?? 20)
        return max(floor, min(fontSize, (width - 2 * padding) / CGFloat(cols) / 0.62))
    }

    /// The window with the lines visible at `t`, font size fitted to the longest line.
    public var body: some View {
        let L = LaunchLayout(ctx)
        let w = width ?? min(L.width, 1240 * L.type)
        // Shrink to fit down to 70% of the authored size; past that a long line wraps once
        // (tiny mono on a phone-sized canvas reads worse than a wrapped command).
        let fs = Self.fittedFontSize(lines, prompt: prompt, width: w, padding: 32 * L.type,
                                     fontSize: fontSize * L.type, floor: fontSize * L.type * 0.7)
        let perRow = max(1, Int((w - 64 * L.type) / (fs * 0.62)))
        let rows = lines.reduce(0) { $0 + min(2, (Self.columns($1, prompt: prompt) + perRow - 1) / perRow) }
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                HStack(spacing: 9 * L.type) {
                    Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34))
                    Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18))
                    Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25))
                }
                .frame(width: 62 * L.type, height: 13 * L.type)
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(title ?? "Terminal").font(theme.text(17 * L.type, .medium)).foregroundStyle(Color.white.opacity(0.5))
            }
            .padding(.horizontal, 22 * L.type).frame(height: 52 * L.type)
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
            VStack(alignment: .leading, spacing: fs * 0.55) {
                ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                    if t >= line.at { row(line, i, fs) }
                }
            }
            .padding(.horizontal, 32 * L.type).padding(.vertical, 30 * L.type)
            .frame(maxWidth: .infinity, minHeight: fs * 1.5 * CGFloat(max(3, rows)) + 60 * L.type, alignment: .topLeading)
        }
        .frame(width: w)
        .background(RoundedRectangle(cornerRadius: 22 * L.type, style: .continuous).fill(Color(white: 0.07).opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 22 * L.type, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(theme.isDark ? 0.6 : 0.2), radius: 40, y: 24)
    }

    private func row(_ line: Line, _ i: Int, _ fs: CGFloat) -> some View {
        let mono = Font.system(size: fs, weight: .regular, design: .monospaced)
        let laterCommand = lines[(i + 1)...].first { $0.kind == .command }?.at ?? .infinity
        let isLastCommand = line.kind == .command && !lines[(i + 1)...].contains { $0.kind == .command && t >= $0.at }
        let typed = Motion.typed(line.text, t, start: line.at, cps: cps)
        let typing = typed.count < line.text.count
        let caretOn = line.kind == .command && isLastCommand && t < laterCommand && (typing || Int(t * 2) % 2 == 0)
        var text: Text
        switch line.kind {
        case .command:
            text = Text(prompt).foregroundColor(theme.accent).fontWeight(.semibold) + Text(typed).foregroundColor(.white)
            if caretOn { text = text + Text("▍").foregroundColor(Color.white.opacity(0.85)) }
        case .output: text = Text(line.text).foregroundColor(Color.white.opacity(0.55))
        case .comment: text = Text(line.text).foregroundColor(Color.white.opacity(0.35))
        case .success: text = Text(line.text).foregroundColor(theme.accent)
        case .failure: text = Text(line.text).foregroundColor(Color(red: 1, green: 0.42, blue: 0.4))
        }
        return text.font(mono).lineLimit(2).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
    }
}
