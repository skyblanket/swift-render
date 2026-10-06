import Foundation

// MARK: - LaunchProps
//
// Everything an Apple-style launch film needs to know about a codebase. The
// scanner fills it from the repo (`LaunchScanner`), `swift-render launch` writes
// it to `.swift-render/launch/<Name>.json`, and the `AppleLaunch` scene renders
// it. Every key is optional when decoding — a hand-written `{"name": "Foo"}` is a
// valid film — so agents and Studio knobs can edit the JSON freely.
//
// Foundation-only: colors are hex strings, symbols are SF Symbol names.

public struct LaunchProps: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case app, library, cli, framework, plugin }
    public enum Appearance: String, Codable, Sendable { case dark, light }
    /// Display face. `sfPro` is the Apple look; `inter` (SIL OFL, bundled) is the
    /// license-safe fallback for commercial renders.
    public enum Typeface: String, Codable, Sendable, CaseIterable { case sfPro, sfRounded, newYork, inter }
    /// `iOS` clips to the continuous-corner squircle; `macOS` art already carries its shape.
    public enum IconShape: String, Codable, Sendable { case iOS, macOS, none }
    public enum Device: String, Codable, Sendable { case iPhone, iPad, mac, macWindow }
    public enum CodeLanguage: String, Codable, Sendable { case swift, shell, json, plain }
    /// How a stat is printed: 1,234 · 1.2k · 98% · 10×.
    public enum StatFormat: String, Codable, Sendable { case integer, compact, percent, multiplier }

    public struct Icon: Codable, Sendable, Equatable {
        /// Image path, absolute or relative to the project root.
        public var path: String
        public var darkPath: String?
        public var shape: IconShape
        public init(path: String, darkPath: String? = nil, shape: IconShape = .iOS) {
            self.path = path; self.darkPath = darkPath; self.shape = shape
        }
    }

    public struct Feature: Codable, Sendable, Equatable {
        /// ≤ 4 words.
        public var title: String
        /// ≤ 80 characters.
        public var detail: String
        /// SF Symbol name.
        public var symbol: String
        public var screenshot: String?
        public init(title: String, detail: String = "", symbol: String = "sparkle", screenshot: String? = nil) {
            self.title = title; self.detail = detail; self.symbol = symbol; self.screenshot = screenshot
        }
    }

    public struct CodeSnippet: Codable, Sendable, Equatable {
        public var source: String
        public var language: CodeLanguage
        /// Tab label, e.g. "ContentView.swift".
        public var title: String?
        /// 1-based lines kept bright once the snippet is in.
        public var focus: [Int]?
        /// Headline shown beside the code.
        public var caption: String?
        public init(source: String, language: CodeLanguage = .swift, title: String? = nil,
                    focus: [Int]? = nil, caption: String? = nil) {
            self.source = source; self.language = language; self.title = title
            self.focus = focus; self.caption = caption
        }
    }

    /// Raw numbers, each traceable to a source. The film only shows `highlights`.
    public struct Stats: Codable, Sendable, Equatable {
        public var stars: Int?, forks: Int?, commits: Int?, contributors: Int?
        public var swiftLines: Int?, testCount: Int?, dependencies: Int?, releases: Int?, targets: Int?
        /// yyyy-MM-dd
        public var firstCommit: String?
        public init(stars: Int? = nil, forks: Int? = nil, commits: Int? = nil, contributors: Int? = nil,
                    swiftLines: Int? = nil, testCount: Int? = nil, dependencies: Int? = nil,
                    releases: Int? = nil, targets: Int? = nil, firstCommit: String? = nil) {
            self.stars = stars; self.forks = forks; self.commits = commits; self.contributors = contributors
            self.swiftLines = swiftLines; self.testCount = testCount; self.dependencies = dependencies
            self.releases = releases; self.targets = targets; self.firstCommit = firstCommit
        }
    }

    /// One number on the stats shot.
    public struct Stat: Codable, Sendable, Equatable {
        public var value: Double
        public var format: StatFormat
        public var label: String
        public var prefix: String?
        public var suffix: String?
        /// Where the number came from ("git rev-list", "Tests/").
        public var source: String?
        public init(value: Double, format: StatFormat = .integer, label: String,
                    prefix: String? = nil, suffix: String? = nil, source: String? = nil) {
            self.value = value; self.format = format; self.label = label
            self.prefix = prefix; self.suffix = suffix; self.source = source
        }
    }

    public struct Platform: Codable, Sendable, Equatable {
        public enum Name: String, Codable, Sendable, CaseIterable { case iOS, macOS, watchOS, tvOS, visionOS, macCatalyst, linux }
        public var name: Name
        public var minimum: String?
        public init(_ name: Name, minimum: String? = nil) { self.name = name; self.minimum = minimum }
    }

    public struct ChangelogItem: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case added, changed, fixed, performance, removed, security, deprecated }
        public var kind: Kind
        public var title: String
        public var detail: String?
        public init(_ kind: Kind = .added, _ title: String, detail: String? = nil) {
            self.kind = kind; self.title = title; self.detail = detail
        }
    }

    public struct Screenshot: Codable, Sendable, Equatable {
        public var path: String
        public var device: Device
        public var caption: String?
        public init(path: String, device: Device = .iPhone, caption: String? = nil) {
            self.path = path; self.device = device; self.caption = caption
        }
    }

    /// The closing call to action. Generic capsules only — never store-badge artwork.
    public struct CTA: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case availableNow, downloadForMac, appStore, swiftPackage, github, brew, custom }
        public var kind: Kind
        /// Button label override.
        public var title: String?
        /// Package URL / `owner/repo` / formula, depending on `kind`.
        public var value: String?
        /// Version for `.swiftPackage` (`from:`).
        public var from: String?
        public var symbol: String?
        public init(_ kind: Kind = .availableNow, title: String? = nil, value: String? = nil,
                    from: String? = nil, symbol: String? = nil) {
            self.kind = kind; self.title = title; self.value = value; self.from = from; self.symbol = symbol
        }
    }

    public struct Music: Codable, Sendable, Equatable {
        public enum Mood: String, Codable, Sendable { case calm, bright, driving }
        /// 90, 100 or 120 — tempos whose beats land on whole frames at 60 fps.
        public var bpm: Double
        /// Semitone transpose from D.
        public var key: Int
        public var mood: Mood
        public init(bpm: Double = 100, key: Int = 0, mood: Mood = .bright) {
            self.bpm = bpm; self.key = key; self.mood = mood
        }
    }

    /// Per-shot edits from Studio or the agent: `{"id": "changelog", "bars": 1}` or `{"id": "stats", "hidden": true}`.
    public struct ShotOverride: Codable, Sendable, Equatable {
        public var id: String
        public var bars: Double?
        public var hidden: Bool?
        public init(id: String, bars: Double? = nil, hidden: Bool? = nil) {
            self.id = id; self.bars = bars; self.hidden = hidden
        }
    }

    public var schemaVersion: Int
    public var name: String
    /// One sentence, ≤ 60 characters.
    public var tagline: String
    public var subtitle: String?
    public var kind: Kind
    /// Normalized, no leading "v".
    public var version: String?
    public var releaseDate: String?
    public var license: String?
    public var url: String?
    /// "owner/name"
    public var repo: String?
    /// "#RRGGBB"
    public var accent: String
    public var accentSecondary: String?
    public var appearance: Appearance
    public var typeface: Typeface
    public var icon: Icon?
    /// 3…6 read best.
    public var features: [Feature]
    public var code: CodeSnippet?
    public var install: CodeSnippet?
    /// Shell session for the terminal shot: lines starting with "$ " are typed commands.
    public var terminal: [String]?
    public var stats: Stats
    /// 0…3 numbers for the stats shot.
    public var highlights: [Stat]
    public var platforms: [Platform]
    public var swiftVersion: String?
    /// Short facts for the platforms shot ("Zero dependencies").
    public var facts: [String]
    public var changelog: [ChangelogItem]
    public var screenshots: [Screenshot]
    public var cta: CTA
    /// Speak a voiceover (local TTS) over the film.
    public var voiceover: Bool
    /// Voiceover lines by shot id ("hero", "title", "triad", "end", …). Missing shots get generated lines.
    public var voiceoverLines: [String: String]?
    public var music: Music
    public var shots: [ShotOverride]

    public init(name: String, tagline: String = "", subtitle: String? = nil, kind: Kind = .app,
                version: String? = nil, releaseDate: String? = nil, license: String? = nil,
                url: String? = nil, repo: String? = nil, accent: String = "#0A84FF", accentSecondary: String? = nil,
                appearance: Appearance = .dark, typeface: Typeface = .sfPro, icon: Icon? = nil,
                features: [Feature] = [], code: CodeSnippet? = nil, install: CodeSnippet? = nil,
                terminal: [String]? = nil, stats: Stats = Stats(), highlights: [Stat] = [],
                platforms: [Platform] = [], swiftVersion: String? = nil, facts: [String] = [],
                changelog: [ChangelogItem] = [], screenshots: [Screenshot] = [], cta: CTA = CTA(),
                voiceover: Bool = false, voiceoverLines: [String: String]? = nil,
                music: Music = Music(), shots: [ShotOverride] = []) {
        self.schemaVersion = 1
        self.name = name; self.tagline = tagline; self.subtitle = subtitle; self.kind = kind
        self.version = version; self.releaseDate = releaseDate; self.license = license
        self.url = url; self.repo = repo; self.accent = accent; self.accentSecondary = accentSecondary
        self.appearance = appearance; self.typeface = typeface; self.icon = icon
        self.features = features; self.code = code; self.install = install; self.terminal = terminal
        self.stats = stats; self.highlights = highlights; self.platforms = platforms
        self.swiftVersion = swiftVersion; self.facts = facts; self.changelog = changelog
        self.screenshots = screenshots; self.cta = cta; self.voiceover = voiceover
        self.voiceoverLines = voiceoverLines; self.music = music; self.shots = shots
    }

    /// What a bare `{}` decodes to.
    public static let fallback = LaunchProps(name: "Your App", tagline: "Something new.")

    /// A complete example (a fictional notes app) — the `props` template and the scene's default.
    public static let sample = LaunchProps(
        name: "Lumen",
        tagline: "Notes that think with you.",
        subtitle: "Private, on-device intelligence for everything you write.",
        kind: .app, version: "2.0", license: "MIT",
        url: "lumen.app",
        accent: "#FFB340", accentSecondary: "#FF6A3D",
        features: [
            Feature(title: "Instant search", detail: "Find any note by meaning, not just words.", symbol: "magnifyingglass"),
            Feature(title: "On-device", detail: "Your notes never leave your Mac.", symbol: "lock.fill"),
            Feature(title: "Live sync", detail: "iPhone, iPad and Mac, always in step.", symbol: "arrow.triangle.2.circlepath"),
            Feature(title: "Smart folders", detail: "Notes file themselves as you write.", symbol: "folder.fill"),
            Feature(title: "Markdown", detail: "Headings, lists and code, as you type.", symbol: "text.alignleft"),
        ],
        code: CodeSnippet(source: """
            import SwiftUI

            struct NoteRow: View {
                let note: Note

                var body: some View {
                    VStack(alignment: .leading) {
                        Text(note.title).font(.headline)
                        Text(note.summary)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            """, title: "NoteRow.swift", focus: [7, 8, 9, 10], caption: "Built in SwiftUI."),
        terminal: ["$ brew install lumen", "==> Pouring lumen--2.0.arm64_sequoia.bottle.tar.gz", "✓ lumen 2.0 installed"],
        stats: Stats(commits: 1284, contributors: 12, testCount: 640),
        highlights: [
            Stat(value: 640, format: .integer, label: "tests", source: "sample"),
            Stat(value: 1284, format: .compact, label: "commits", source: "sample"),
            Stat(value: 12, format: .integer, label: "contributors", source: "sample"),
        ],
        platforms: [Platform(.iOS, minimum: "17"), Platform(.macOS, minimum: "14"), Platform(.visionOS, minimum: "1")],
        swiftVersion: "6.0",
        facts: ["Zero tracking"],
        changelog: [
            ChangelogItem(.added, "Semantic search across every note"),
            ChangelogItem(.added, "Smart folders"),
            ChangelogItem(.performance, "Opens 3× faster on large libraries"),
            ChangelogItem(.fixed, "Sync conflicts on shared notes"),
        ],
        cta: CTA(.downloadForMac)
    )
}

// MARK: - Lenient decoding

extension KeyedDecodingContainer {
    /// Missing, null, wrongly typed or unknown-enum values all fall back to `def`.
    func lenient<T: Decodable>(_ key: Key, _ def: @autoclosure () -> T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? def()
    }
    func lenient<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
    /// Arrays drop the elements that fail instead of failing as a whole.
    func lenientArray<T: Decodable>(_ key: Key) -> [T] {
        guard let items = try? decodeIfPresent([LenientElement<T>].self, forKey: key) else { return [] }
        return items.compactMap(\.value)
    }
}

struct LenientElement<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension LaunchProps {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LaunchProps.fallback
        self.init(name: c.lenient(.name, d.name))
        schemaVersion = c.lenient(.schemaVersion, 1)
        tagline = c.lenient(.tagline, d.tagline)
        subtitle = c.lenient(.subtitle)
        kind = c.lenient(.kind, .app)
        version = c.lenient(.version)
        releaseDate = c.lenient(.releaseDate)
        license = c.lenient(.license)
        url = c.lenient(.url)
        repo = c.lenient(.repo)
        accent = c.lenient(.accent, d.accent)
        accentSecondary = c.lenient(.accentSecondary)
        appearance = c.lenient(.appearance, .dark)
        typeface = c.lenient(.typeface, .sfPro)
        icon = c.lenient(.icon)
        features = c.lenientArray(.features)
        code = c.lenient(.code)
        install = c.lenient(.install)
        terminal = c.lenient(.terminal)
        stats = c.lenient(.stats, Stats())
        highlights = c.lenientArray(.highlights)
        platforms = c.lenientArray(.platforms)
        swiftVersion = c.lenient(.swiftVersion)
        facts = c.lenient(.facts, [])
        changelog = c.lenientArray(.changelog)
        screenshots = c.lenientArray(.screenshots)
        cta = c.lenient(.cta, CTA())
        voiceover = c.lenient(.voiceover, false)
        voiceoverLines = c.lenient(.voiceoverLines)
        music = c.lenient(.music, Music())
        shots = c.lenientArray(.shots)
    }
}

extension LaunchProps.Icon {
    public init(from decoder: Decoder) throws {
        // "icon": "path/to.png" is accepted as shorthand.
        if let s = try? decoder.singleValueContainer().decode(String.self) { self.init(path: s); return }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let path: String = c.lenient(.path) else {
            throw DecodingError.keyNotFound(CodingKeys.path, .init(codingPath: c.codingPath, debugDescription: "icon needs a path"))
        }
        self.init(path: path, darkPath: c.lenient(.darkPath), shape: c.lenient(.shape, .iOS))
    }
}

extension LaunchProps.Feature {
    public init(from decoder: Decoder) throws {
        // "features": ["Fast", "Private"] is accepted as shorthand.
        if let s = try? decoder.singleValueContainer().decode(String.self) { self.init(title: s); return }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let title: String = c.lenient(.title) else {
            throw DecodingError.keyNotFound(CodingKeys.title, .init(codingPath: c.codingPath, debugDescription: "feature needs a title"))
        }
        self.init(title: title, detail: c.lenient(.detail, ""), symbol: c.lenient(.symbol, "sparkle"),
                  screenshot: c.lenient(.screenshot))
    }
}

extension LaunchProps.CodeSnippet {
    public init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) { self.init(source: s); return }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(source: c.lenient(.source, ""), language: c.lenient(.language, .swift), title: c.lenient(.title),
                  focus: c.lenient(.focus), caption: c.lenient(.caption))
    }
}

extension LaunchProps.Stats {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(stars: c.lenient(.stars), forks: c.lenient(.forks), commits: c.lenient(.commits),
                  contributors: c.lenient(.contributors), swiftLines: c.lenient(.swiftLines),
                  testCount: c.lenient(.testCount), dependencies: c.lenient(.dependencies),
                  releases: c.lenient(.releases), targets: c.lenient(.targets), firstCommit: c.lenient(.firstCommit))
    }
}

extension LaunchProps.Stat {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let value: Double = c.lenient(.value) else {
            throw DecodingError.keyNotFound(CodingKeys.value, .init(codingPath: c.codingPath, debugDescription: "stat needs a value"))
        }
        self.init(value: value, format: c.lenient(.format, .integer), label: c.lenient(.label, ""),
                  prefix: c.lenient(.prefix), suffix: c.lenient(.suffix), source: c.lenient(.source))
    }
}

extension LaunchProps.Platform {
    public init(from decoder: Decoder) throws {
        // "platforms": ["iOS", "macOS"] is accepted as shorthand.
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            guard let n = Name(rawValue: s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown platform \(s)"))
            }
            self.init(n); return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let name: Name = c.lenient(.name) else {
            throw DecodingError.keyNotFound(CodingKeys.name, .init(codingPath: c.codingPath, debugDescription: "platform needs a name"))
        }
        self.init(name, minimum: c.lenient(.minimum))
    }
}

extension LaunchProps.ChangelogItem {
    public init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) { self.init(.added, s); return }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let title: String = c.lenient(.title) else {
            throw DecodingError.keyNotFound(CodingKeys.title, .init(codingPath: c.codingPath, debugDescription: "changelog item needs a title"))
        }
        self.init(c.lenient(.kind, .added), title, detail: c.lenient(.detail))
    }
}

extension LaunchProps.Screenshot {
    public init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) { self.init(path: s); return }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let path: String = c.lenient(.path) else {
            throw DecodingError.keyNotFound(CodingKeys.path, .init(codingPath: c.codingPath, debugDescription: "screenshot needs a path"))
        }
        self.init(path: path, device: c.lenient(.device, .iPhone), caption: c.lenient(.caption))
    }
}

extension LaunchProps.CTA {
    public init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            self.init(Kind(rawValue: s) ?? .custom, title: Kind(rawValue: s) == nil ? s : nil); return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(c.lenient(.kind, .availableNow), title: c.lenient(.title), value: c.lenient(.value),
                  from: c.lenient(.from), symbol: c.lenient(.symbol))
    }
}

extension LaunchProps.Music {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(bpm: c.lenient(.bpm, 100), key: c.lenient(.key, 0), mood: c.lenient(.mood, .bright))
    }
}

extension LaunchProps.ShotOverride {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id: String = c.lenient(.id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "shot override needs an id"))
        }
        self.init(id: id, bars: c.lenient(.bars), hidden: c.lenient(.hidden))
    }
}

// MARK: - Validation

extension LaunchProps {
    /// Clamps the props into what the film can show well and explains every change.
    /// Pure: no file system or AppKit access (symbol validity is checked at render time).
    public func validated() -> (props: LaunchProps, warnings: [String]) {
        var p = self
        var w: [String] = []
        p.name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.name.isEmpty { p.name = LaunchProps.fallback.name; w.append("name: empty, using \"\(p.name)\"") }

        p.tagline = LaunchText.clean(p.tagline)
        if p.tagline.count > 60 {
            let (head, rest) = LaunchText.splitSentence(p.tagline, limit: 60)
            if p.subtitle == nil, !rest.isEmpty { p.subtitle = rest }
            p.tagline = head
            w.append("tagline: longer than 60 characters, trimmed to \"\(head)\"")
        }
        if let s = p.subtitle, s.count > 110 {
            p.subtitle = LaunchText.truncate(s, 110)
            w.append("subtitle: longer than 110 characters, truncated")
        }

        if p.features.count > 6 {
            w.append("features: \(p.features.count) given, showing the first 6")
            p.features = Array(p.features.prefix(6))
        }
        if p.features.count < 3 {
            for item in p.changelog where item.kind == .added && p.features.count < 3 {
                if !p.features.contains(where: { $0.title == item.title }) {
                    p.features.append(Feature(title: LaunchText.truncate(item.title, 28), detail: item.detail ?? "",
                                              symbol: LaunchText.symbol(for: item.title)))
                }
            }
            if p.features.count < 3 { w.append("features: only \(p.features.count) — the feature shot needs 3") }
        }
        p.features = p.features.map { f in
            var f = f
            if f.title.count > 32 { f.title = LaunchText.truncate(f.title, 32) }
            if f.detail.count > 90 { f.detail = LaunchText.truncate(f.detail, 90) }
            if f.symbol.isEmpty { f.symbol = LaunchText.symbol(for: f.title + " " + f.detail) }
            return f
        }

        if var code = p.code {
            let (trimmed, cut) = LaunchText.trimCode(code.source, maxLines: 16, maxColumns: 64)
            if cut { w.append("code: trimmed to \(trimmed.split(separator: "\n", omittingEmptySubsequences: false).count) lines") }
            code.source = trimmed
            p.code = code.source.isEmpty ? nil : code
        }

        if p.highlights.count > 3 {
            w.append("highlights: \(p.highlights.count) given, showing the first 3")
            p.highlights = Array(p.highlights.prefix(3))
        }
        if p.changelog.count > 5 { p.changelog = Array(p.changelog.prefix(5)) }

        let snapped = LaunchPlan.frameExactBPM(p.music.bpm)
        if snapped != p.music.bpm {
            w.append("music.bpm: \(p.music.bpm) does not land beats on whole frames at 60 fps, using \(Int(snapped))")
            p.music.bpm = snapped
        }

        if LaunchColor.rgb(p.accent) == nil {
            w.append("accent: \"\(p.accent)\" is not #RRGGBB, using \(LaunchProps.fallback.accent)")
            p.accent = LaunchProps.fallback.accent
        }
        let readable = LaunchColor.readable(p.accent, onDark: p.appearance == .dark)
        if readable.lowercased() != p.accent.lowercased() {
            w.append("accent: \(p.accent) is under 3:1 contrast on the background, adjusted to \(readable)")
            p.accent = readable
        }
        if let v = p.version { p.version = LaunchText.normalizeVersion(v) }
        return (p, w)
    }
}

// MARK: - Text helpers (shared by the scanner and validation)

public enum LaunchText {
    /// Strips markdown emphasis, links, inline code ticks, HTML tags and emoji shortcodes.
    public static func clean(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(\*\*|__|\*|_|`)"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #":[a-z0-9_+-]+:"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cut at a word boundary with an ellipsis.
    public static func truncate(_ s: String, _ limit: Int) -> String {
        guard s.count > limit else { return s }
        let head = String(s.prefix(limit - 1))
        if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) > limit / 2 {
            return String(head[..<space]).trimmingCharacters(in: .punctuationCharacters) + "…"
        }
        return head + "…"
    }

    /// First sentence (≤ limit) and the remainder.
    public static func splitSentence(_ s: String, limit: Int) -> (String, String) {
        let text = clean(s)
        if let r = text.range(of: #"[.!?](\s|$)"#, options: .regularExpression),
           text.distance(from: text.startIndex, to: r.lowerBound) < limit {
            let head = String(text[...r.lowerBound])
            let rest = String(text[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            return (head, rest)
        }
        return (truncate(text, limit), "")
    }

    public static func normalizeVersion(_ v: String) -> String {
        var s = v.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        return s
    }

    /// ≤ maxLines lines, cut after a line that closes the braces opened so far
    /// when possible; long lines are clipped. Returns (code, wasCut).
    public static func trimCode(_ source: String, maxLines: Int, maxColumns: Int) -> (String, Bool) {
        var lines = source.replacingOccurrences(of: "\t", with: "    ")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        var cut = false
        if lines.count > maxLines {
            cut = true
            var depth = 0, best = -1
            for (i, line) in lines.prefix(maxLines).enumerated() {
                depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
                if depth == 0 && i >= maxLines / 2 { best = i }
            }
            lines = Array(lines.prefix(best >= 0 ? best + 1 : maxLines))
            if best < 0 {
                // No balanced cut point: drop lines until the closing braces fit, then
                // close what is still open so the snippet reads as finished Swift.
                func depth(_ ls: [String]) -> Int {
                    let all = ls.joined()
                    return max(0, all.filter { $0 == "{" }.count - all.filter { $0 == "}" }.count)
                }
                while lines.count > 1 && lines.count + depth(lines) > maxLines { lines.removeLast() }
                for level in stride(from: depth(lines) - 1, through: 0, by: -1) {
                    lines.append(String(repeating: " ", count: level * 4) + "}")
                }
            }
        }
        lines = lines.map { line in
            guard line.count > maxColumns else { return line }
            cut = true
            return String(line.prefix(maxColumns - 1)) + "…"
        }
        return (lines.joined(separator: "\n"), cut)
    }

    /// SF Symbol for a feature by keyword.
    public static func symbol(for text: String) -> String {
        let s = text.lowercased()
        let map: [([String], String)] = [
            (["fast", "speed", "perform", "quick", "instant", "faster"], "bolt.fill"),
            (["private", "privacy", "on-device", "secure", "security", "encrypt", "local"], "lock.fill"),
            (["audio", "sound", "music", "voice", "speech"], "waveform"),
            (["video", "render", "film", "movie", "frame"], "film"),
            (["gpu", "shader", "metal", "graphics"], "cpu"),
            (["ai", "model", "intelligen", "smart", "llm", "agent"], "sparkles"),
            (["test", "reliab", "determinis", "correct"], "checkmark.seal.fill"),
            (["search", "find"], "magnifyingglass"),
            (["3d", "depth", "spatial"], "cube.fill"),
            (["dependenc", "lightweight", "package", "install"], "shippingbox.fill"),
            (["sync", "cloud"], "arrow.triangle.2.circlepath"),
            (["spring", "animat", "motion"], "wand.and.stars"),
            (["timeline", "sequenc", "schedul", "calendar"], "timeline.selection"),
            (["data", "json", "props", "codable"], "doc.text.fill"),
            (["design", "color", "theme", "style", "look"], "paintpalette.fill"),
            (["code", "api", "swift", "developer"], "chevron.left.forwardslash.chevron.right"),
            (["terminal", "cli", "command"], "terminal.fill"),
            (["photo", "image", "camera"], "photo.fill"),
            (["chart", "stat", "analytic", "metric"], "chart.bar.fill"),
            (["note", "write", "text", "markdown"], "text.alignleft"),
            (["share", "collab", "team"], "person.2.fill"),
            (["widget", "glance"], "square.grid.2x2.fill"),
            (["health", "fitness"], "heart.fill"),
            (["map", "location"], "map.fill"),
        ]
        for (keys, symbol) in map where keys.contains(where: { s.contains($0) }) { return symbol }
        return "sparkle"
    }
}

// MARK: - Color math (hex strings; no SwiftUI)

public enum LaunchColor {
    /// (r, g, b) in 0…1 from "#RRGGBB" / "RRGGBB" / "#RRGGBBAA".
    public static func rgb(_ hex: String) -> (Double, Double, Double)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.hasPrefix("0x") { s.removeFirst(2) }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let x = s.count == 8 ? v >> 8 : v
        return (Double((x >> 16) & 0xFF) / 255, Double((x >> 8) & 0xFF) / 255, Double(x & 0xFF) / 255)
    }

    public static func hex(_ r: Double, _ g: Double, _ b: Double) -> String {
        func c(_ v: Double) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }

    /// WCAG relative luminance.
    public static func luminance(_ hex: String) -> Double {
        guard let (r, g, b) = rgb(hex) else { return 0 }
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    public static func contrast(_ a: String, _ b: String) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// The accent, mixed toward white (dark stage) or black (light stage) until it reads at ≥ 3:1.
    public static func readable(_ hex: String, onDark: Bool, minimum: Double = 3) -> String {
        guard let (r, g, b) = rgb(hex) else { return hex }
        let bg = onDark ? "#030304" : "#F5F5F7"
        if contrast(hex, bg) >= minimum { return hex }
        let target = onDark ? 1.0 : 0.0
        for step in 1...20 {
            let k = Double(step) * 0.05
            let c = self.hex(r + (target - r) * k, g + (target - g) * k, b + (target - b) * k)
            if contrast(c, bg) >= minimum { return c }
        }
        return onDark ? "#FFFFFF" : "#000000"
    }
}
