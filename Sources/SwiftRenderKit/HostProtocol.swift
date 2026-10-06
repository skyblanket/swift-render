import Foundation

// MARK: - Render host protocol
//
// Studio never links scene code. It launches `<bin>/<product> serve` in the
// project root and speaks JSON Lines over the child's stdin/stdout:
//
//   → {"id":1,"method":"open","params":{"scene":"Hello","fps":30,"width":1920,"height":1080}}
//   ← {"id":1,"result":{"info":{…SceneInfo…}}}
//   → {"id":2,"method":"frame","params":{"t":1.25,"maxWidth":960}}
//   ← {"id":2,"result":{"frame":{"t":1.25,"width":960,"height":540,"format":"jpeg","data":"<base64>","ms":7.9}}}
//   ← {"event":"log","message":"…"}                     (unsolicited, no id)
//
// The host owns fd 1 for protocol only: on start it dups the real stdout to a
// private fd and points fd 1 at stderr, so a stray `print` in a scene can never
// corrupt the stream. The first line it writes is a `ready` event listing scenes.
// After a rebuild Studio simply kills the host and starts the new binary.
//
// Frame requests are coalesced: if a newer `frame` is already queued when an
// older one is about to render, the older one gets `error.code == "superseded"`.

public enum HostProtocol {
    public static let version = 1
}

public enum HostMethod: String, Codable, Sendable {
    /// → `HostListResult`
    case list
    /// `HostOpenParams` → `HostOpenResult`. Loads knobs from disk unless overridden.
    case open
    /// `HostFrameParams` → `HostFrameResult`. Requires a prior `open`.
    case frame
    /// `HostSetKnobsParams` → `HostOpenResult` (re-probed info with new knob values).
    case setKnobs
    /// `HostSetPropsParams` → `HostOpenResult`.
    case setProps
    /// → `{}` then the host exits 0.
    case shutdown
}

public struct HostRequest: Codable, Sendable {
    public var id: Int
    public var method: HostMethod
    public var params: HostParams?

    public init(id: Int, method: HostMethod, params: HostParams? = nil) {
        self.id = id; self.method = method; self.params = params
    }
}

/// Union of every request's params (unused fields stay nil) — keeps the wire
/// format flat and the decoder trivial on both ends.
public struct HostParams: Codable, Sendable, Equatable {
    // open
    public var scene: String?
    public var duration: Double?
    public var width: Int?
    public var height: Int?
    public var fps: Int?
    public var postFX: Bool?
    /// Props JSON text (PropsScene kinds). nil = scene defaults.
    public var propsJSON: String?
    /// Path to an external audio file (overrides the scene's Score).
    public var audioPath: String?
    // frame
    public var t: Double?
    /// Longest edge cap for the returned image, in pixels (aspect preserved).
    public var maxWidth: Int?
    /// "jpeg" (default, fast) or "png" (lossless, for comparisons/attachments).
    public var format: String?
    public var quality: Double?
    // setKnobs
    public var knobs: [String: KnobValue]?
    /// When true the host also writes the knob file (otherwise values are live-only).
    public var persist: Bool?

    public init(scene: String? = nil, duration: Double? = nil, width: Int? = nil, height: Int? = nil,
                fps: Int? = nil, postFX: Bool? = nil, propsJSON: String? = nil, audioPath: String? = nil,
                t: Double? = nil, maxWidth: Int? = nil, format: String? = nil, quality: Double? = nil,
                knobs: [String: KnobValue]? = nil, persist: Bool? = nil) {
        self.scene = scene; self.duration = duration; self.width = width; self.height = height
        self.fps = fps; self.postFX = postFX; self.propsJSON = propsJSON; self.audioPath = audioPath
        self.t = t; self.maxWidth = maxWidth; self.format = format; self.quality = quality
        self.knobs = knobs; self.persist = persist
    }
}

public struct HostError: Codable, Sendable, Equatable, Error {
    /// "superseded" | "noScene" | "unknownScene" | "badParams" | "renderFailed" | "internal"
    public var code: String
    public var message: String
    public init(code: String, message: String) { self.code = code; self.message = message }
}

public struct HostFrame: Codable, Sendable, Equatable {
    public var t: Double
    public var width: Int
    public var height: Int
    public var format: String
    /// Base64 image bytes.
    public var data: String
    /// Wall time spent rendering + encoding, milliseconds.
    public var ms: Double
    public init(t: Double, width: Int, height: Int, format: String, data: String, ms: Double) {
        self.t = t; self.width = width; self.height = height; self.format = format; self.data = data; self.ms = ms
    }
}

/// Union of every result (unused fields nil).
public struct HostResult: Codable, Sendable, Equatable {
    public var scenes: [SceneSummary]?
    public var info: SceneInfo?
    public var frame: HostFrame?
    public init(scenes: [SceneSummary]? = nil, info: SceneInfo? = nil, frame: HostFrame? = nil) {
        self.scenes = scenes; self.info = info; self.frame = frame
    }
}

/// Every line the host writes is one `HostMessage`.
public struct HostMessage: Codable, Sendable {
    /// Present on responses.
    public var id: Int?
    public var result: HostResult?
    public var error: HostError?
    /// Present on unsolicited events: "ready" | "log" | "warning".
    public var event: String?
    public var message: String?
    /// `ready` carries the scene list and host version.
    public var scenes: [SceneSummary]?
    public var version: String?
    public var protocolVersion: Int?

    public init(id: Int? = nil, result: HostResult? = nil, error: HostError? = nil, event: String? = nil,
                message: String? = nil, scenes: [SceneSummary]? = nil, version: String? = nil,
                protocolVersion: Int? = nil) {
        self.id = id; self.result = result; self.error = error; self.event = event; self.message = message
        self.scenes = scenes; self.version = version; self.protocolVersion = protocolVersion
    }

    public static func response(_ id: Int, _ result: HostResult) -> HostMessage { HostMessage(id: id, result: result) }
    public static func failure(_ id: Int, _ error: HostError) -> HostMessage { HostMessage(id: id, error: error) }
    public static func ready(scenes: [SceneSummary], version: String) -> HostMessage {
        HostMessage(event: "ready", scenes: scenes, version: version, protocolVersion: HostProtocol.version)
    }
    public static func log(_ text: String) -> HostMessage { HostMessage(event: "log", message: text) }
}

/// One-line JSON encode/decode shared by both ends.
public enum HostWire {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        var data = try enc.encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, line: Data) throws -> T {
        try JSONDecoder().decode(T.self, from: line)
    }
}

/// Splits a byte stream into newline-terminated lines (handles partial reads).
public struct LineBuffer: Sendable {
    private var buffer = Data()
    public init() {}

    public mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            if !line.isEmpty { lines.append(Data(line)) }
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        return lines
    }
}
