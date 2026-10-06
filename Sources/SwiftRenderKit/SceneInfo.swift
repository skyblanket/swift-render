import Foundation

// MARK: - Scene metadata
//
// What a host (render server, `swift-render info --json`, MCP) can tell an
// editor or agent about a scene without the editor linking the scene code.
// All times are absolute seconds from scene start.

public enum SceneKind: String, Codable, Sendable {
    case render, audio, props, propsAudio
}

public struct SceneSummary: Codable, Sendable, Equatable, Hashable {
    public var name: String
    public var kind: SceneKind
    public var defaultDuration: Double
    public var hasSoundtrack: Bool
    public var hasProps: Bool

    public init(name: String, kind: SceneKind, defaultDuration: Double, hasSoundtrack: Bool, hasProps: Bool) {
        self.name = name; self.kind = kind; self.defaultDuration = defaultDuration
        self.hasSoundtrack = hasSoundtrack; self.hasProps = hasProps
    }
}

/// Where in the source a timeline element was declared.
public struct SourceLocation: Codable, Sendable, Equatable, Hashable {
    public var file: String
    public var line: Int
    public init(file: String, line: Int) { self.file = file; self.line = line }
}

/// One clip as placed on the (possibly nested) timeline.
public struct ClipInfo: Codable, Sendable, Equatable, Hashable {
    /// Stable across probes of the same code: "<depth>:<start>:<line>" (start to the
    /// millisecond; a "~n" suffix separates clips that would otherwise collide).
    public var id: String
    /// `Clip(...).named("Hero")`, else nil (editors show "Clip · File.swift:42").
    public var label: String?
    public var start: Double
    public var end: Double
    /// 0 = top-level Timeline; nested Timelines inside a clip are depth+1.
    public var depth: Int
    public var pinned: Bool
    /// Transition *into* this clip: "cut", "fade", "slide", "flash", "overlap", or a custom name.
    public var transitionIn: String
    public var transitionDuration: Double
    public var source: SourceLocation?
    /// `id` of the clip whose content holds this clip's Timeline; nil at depth 0.
    public var parentID: String?
    /// The enclosing Timeline's `label:`, if any.
    public var timelineLabel: String?
    /// Where the enclosing `Timeline(…)` was written.
    public var timelineSource: SourceLocation?

    public init(id: String, label: String?, start: Double, end: Double, depth: Int, pinned: Bool,
                transitionIn: String, transitionDuration: Double, source: SourceLocation?,
                parentID: String? = nil, timelineLabel: String? = nil, timelineSource: SourceLocation? = nil) {
        self.id = id; self.label = label; self.start = start; self.end = end; self.depth = depth
        self.pinned = pinned; self.transitionIn = transitionIn
        self.transitionDuration = transitionDuration; self.source = source
        self.parentID = parentID; self.timelineLabel = timelineLabel; self.timelineSource = timelineSource
    }

    /// The id format: `ClipInfo.id(depth: 1, start: 21.26, line: 284)` → "1:21.260:284".
    public static func id(depth: Int, start: Double, line: Int) -> String {
        String(format: "%d:%.3f:%d", depth, start + 0, line)   // + 0 turns -0 into 0
    }

    /// What an editor shows: the label, else "File.swift:42", else the id.
    public var displayName: String {
        label ?? source.map { "\(($0.file as NSString).lastPathComponent):\($0.line)" } ?? id
    }

    public var duration: Double { end - start }
    public func contains(_ t: Double) -> Bool { t >= start && t < end }
}

/// One Score event, flattened for a timeline lane.
public struct ScoreEventInfo: Codable, Sendable, Equatable, Hashable {
    /// "drums" | "mark" | "melodic" | "sample" | "speech" | "fx"
    public var lane: String
    /// Short name: "kick", "swell", "pluck", "sample", "speak", …
    public var kind: String
    /// Human detail: note name / sample path / spoken text.
    public var detail: String?
    public var time: Double
    public var duration: Double
    public var amp: Double

    public init(lane: String, kind: String, detail: String?, time: Double, duration: Double, amp: Double) {
        self.lane = lane; self.kind = kind; self.detail = detail
        self.time = time; self.duration = duration; self.amp = amp
    }
}

/// A live-tunable constant declared by `Knob.double("key", …)` & friends.
public struct KnobInfo: Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable { case double, bool, text, color }
    public var key: String
    public var kind: Kind
    public var defaultValue: KnobValue
    /// Current value (override if one is set, else the default).
    public var value: KnobValue
    public var min: Double?
    public var max: Double?
    public var source: SourceLocation?

    public init(key: String, kind: Kind, defaultValue: KnobValue, value: KnobValue,
                min: Double? = nil, max: Double? = nil, source: SourceLocation? = nil) {
        self.key = key; self.kind = kind; self.defaultValue = defaultValue; self.value = value
        self.min = min; self.max = max; self.source = source
    }
}

/// A knob value as stored in `.swift-render/knobs/<Scene>.json`:
/// a JSON number, bool, or string (colors are "#RRGGBB" / "#RRGGBBAA" strings).
public enum KnobValue: Codable, Sendable, Equatable, Hashable {
    case number(Double)
    case bool(Bool)
    case string(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        self = .string(try c.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .string(let s): try c.encode(s)
        }
    }

    public var doubleValue: Double? { if case .number(let d) = self { return d }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
}

/// Load/save knob overrides for one scene. Missing file = no overrides.
public enum KnobFile {
    public static func load(_ url: URL) -> [String: KnobValue] {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: KnobValue].self, from: data) else { return [:] }
        return dict
    }

    public static func save(_ values: [String: KnobValue], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if values.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(values).write(to: url, options: .atomic)
    }
}

public struct CaptionInfo: Codable, Sendable, Equatable, Hashable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
}

/// Everything an editor needs to lay out a scene's timeline.
public struct SceneInfo: Codable, Sendable, Equatable {
    public var name: String
    public var kind: SceneKind
    public var duration: Double
    public var width: Int
    public var height: Int
    public var fps: Int
    public var clips: [ClipInfo]
    public var events: [ScoreEventInfo]
    public var knobs: [KnobInfo]
    public var captions: [CaptionInfo]
    /// Pretty JSON of the props in effect (PropsScene kinds only).
    public var propsJSON: String?
    /// WAV/m4a the editor should play in sync (synthesized score or --audio file).
    public var audioPath: String?
    /// RMS loudness envelope, `loudnessRate` samples per second, 0…1.
    public var loudness: [Float]
    public var loudnessRate: Double
    /// Absolute path of the file declaring the scene, when known.
    public var sourcePath: String?

    public init(name: String, kind: SceneKind, duration: Double, width: Int, height: Int, fps: Int,
                clips: [ClipInfo] = [], events: [ScoreEventInfo] = [], knobs: [KnobInfo] = [],
                captions: [CaptionInfo] = [], propsJSON: String? = nil, audioPath: String? = nil,
                loudness: [Float] = [], loudnessRate: Double = 50, sourcePath: String? = nil) {
        self.name = name; self.kind = kind; self.duration = duration
        self.width = width; self.height = height; self.fps = fps
        self.clips = clips; self.events = events; self.knobs = knobs; self.captions = captions
        self.propsJSON = propsJSON; self.audioPath = audioPath
        self.loudness = loudness; self.loudnessRate = loudnessRate; self.sourcePath = sourcePath
    }

    /// Clips active at `t`, outermost first.
    public func clips(at t: Double) -> [ClipInfo] {
        clips.filter { $0.contains(t) }.sorted { ($0.depth, $0.start) < ($1.depth, $1.start) }
    }
}
