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
//
// Playback uses `stream`: the host pushes `frame` events tagged with the stream's
// request id while it has credit; the client grants more with `credit` and stops
// with `cancel`. With `binaryFrames: true` on `open`, frames may be sent as a JSON
// line whose `frame.bytes` is set, followed immediately by exactly that many raw
// bytes (format "bgra8": width*4 row bytes, premultiplied alpha first, sRGB).
// `HostStreamDecoder` handles both framings.
//
// Unsolicited events: "ready", "log", "warning", "frame" (stream), "info" (a
// SceneInfo with newly discovered clips/knobs), "audio" (score audio ready after
// background synthesis: `audioPath` + `loudness`).
//
// Host behaviour clients can rely on (`swift-render serve`):
// - Requests are handled in arrival order, except that only the newest pending
//   `frame` renders; stream frames render between requests.
// - `open` answers before score audio exists. When the synthesized WAV is already
//   cached its path is in `info.audioPath`; `loudness` (and voiceover `captions`)
//   arrive later: an "audio" event, then an "info" event if captions changed.
//   For audio-reactive kinds (`audio`, `propsAudio`) frames rendered before the
//   "audio" event used a silent track: drop cached frames when it arrives.
// - "info" is also sent when a frame declares a knob the probe didn't see.
// - A stream that reaches `to` (or the scene end) sends `{"event":"streamEnd",
//   "streamID":N}` after its last frame; `message` is set if it stopped on an error.
//   `cancel` answers `{}` and sends no streamEnd; no frame for that stream follows
//   the `{}`. A new `stream` or `open` ends the previous stream (streamEnd).
// - stdin EOF or `shutdown` → exit 0. Crashes print the signal and the scene/t
//   being rendered to stderr before the default handler (or Swift backtracer) runs.

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
    /// `from`, `to?`, `fps?`, `maxWidth`, `format`, `credits` → `{}`; then `frame` events
    /// tagged `streamID` = this request's id until `to`/end, cancel, or credit runs out.
    /// `credits` defaults to 4; at 0 the stream pauses until `credit`.
    case stream
    /// `streamID`, `credits` → `{}`. Grants the stream more frames.
    case credit
    /// `streamID` → `{}`. Stops a stream.
    case cancel
    /// `t`, `path`, `maxWidth?`, `format?` ("png" default) → `result.path`. Lossless still
    /// written by the host (comment attachments, compare).
    case still
    /// `path` (contact sheet PNG) → `result.path` + `result.report` (the `check` report lines).
    case check
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
    /// The complete override set: keys left out revert to their source defaults.
    /// Also accepted on `open` (instead of the project's knob file).
    public var knobs: [String: KnobValue]?
    /// When true the host also writes the knob file (otherwise values are live-only).
    public var persist: Bool?
    /// On setKnobs/setProps: false while a slider is dragging (skip the structure re-probe).
    public var reprobe: Bool?
    /// On `open`: the client accepts header-line + raw "bgra8" payload frames.
    public var binaryFrames: Bool?
    // stream / credit / cancel
    public var from: Double?
    public var to: Double?
    public var credits: Int?
    public var streamID: Int?
    // still / check
    public var path: String?

    public init(scene: String? = nil, duration: Double? = nil, width: Int? = nil, height: Int? = nil,
                fps: Int? = nil, postFX: Bool? = nil, propsJSON: String? = nil, audioPath: String? = nil,
                t: Double? = nil, maxWidth: Int? = nil, format: String? = nil, quality: Double? = nil,
                knobs: [String: KnobValue]? = nil, persist: Bool? = nil, reprobe: Bool? = nil,
                binaryFrames: Bool? = nil, from: Double? = nil, to: Double? = nil, credits: Int? = nil,
                streamID: Int? = nil, path: String? = nil) {
        self.scene = scene; self.duration = duration; self.width = width; self.height = height
        self.fps = fps; self.postFX = postFX; self.propsJSON = propsJSON; self.audioPath = audioPath
        self.t = t; self.maxWidth = maxWidth; self.format = format; self.quality = quality
        self.knobs = knobs; self.persist = persist; self.reprobe = reprobe; self.binaryFrames = binaryFrames
        self.from = from; self.to = to; self.credits = credits; self.streamID = streamID; self.path = path
    }
}

public struct HostError: Codable, Sendable, Equatable, Error {
    /// "superseded" | "noScene" | "unknownScene" | "badParams" | "renderFailed" | "internal"
    public var code: String
    public var message: String
    public init(code: String, message: String) { self.code = code; self.message = message }
}

public extension HostError {
    /// The `code` strings the host sends.
    enum Code {
        /// A newer `frame` request replaced this one before it rendered.
        public static let superseded = "superseded"
        /// The request needs a prior successful `open`.
        public static let noScene = "noScene"
        public static let unknownScene = "unknownScene"
        public static let badParams = "badParams"
        public static let renderFailed = "renderFailed"
        public static let `internal` = "internal"
    }
}

public struct HostFrame: Codable, Sendable, Equatable {
    public var t: Double
    public var width: Int
    public var height: Int
    /// "jpeg" | "png" | "bgra8"
    public var format: String
    /// Base64 image bytes ("" when `bytes` is set and a raw payload follows).
    public var data: String
    /// Wall time spent rendering + encoding, milliseconds.
    public var ms: Double
    /// Frame number at the opened fps.
    public var index: Int?
    /// Non-nil ⇒ exactly this many raw bytes follow the JSON line.
    public var bytes: Int?
    public init(t: Double, width: Int, height: Int, format: String, data: String, ms: Double,
                index: Int? = nil, bytes: Int? = nil) {
        self.t = t; self.width = width; self.height = height; self.format = format; self.data = data; self.ms = ms
        self.index = index; self.bytes = bytes
    }
}

/// Union of every result (unused fields nil).
public struct HostResult: Codable, Sendable, Equatable {
    public var scenes: [SceneSummary]?
    public var info: SceneInfo?
    public var frame: HostFrame?
    /// `still` / `check` output file.
    public var path: String?
    /// `check` report lines.
    public var report: [String]?
    public init(scenes: [SceneSummary]? = nil, info: SceneInfo? = nil, frame: HostFrame? = nil,
                path: String? = nil, report: [String]? = nil) {
        self.scenes = scenes; self.info = info; self.frame = frame; self.path = path; self.report = report
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
    /// `frame` events: the stream's request id and the frame.
    public var streamID: Int?
    public var frame: HostFrame?
    /// `info` events: refreshed scene metadata.
    public var info: SceneInfo?
    /// `audio` events: synthesized score file + loudness envelope.
    public var audioPath: String?
    public var loudness: [Float]?

    public init(id: Int? = nil, result: HostResult? = nil, error: HostError? = nil, event: String? = nil,
                message: String? = nil, scenes: [SceneSummary]? = nil, version: String? = nil,
                protocolVersion: Int? = nil, streamID: Int? = nil, frame: HostFrame? = nil,
                info: SceneInfo? = nil, audioPath: String? = nil, loudness: [Float]? = nil) {
        self.id = id; self.result = result; self.error = error; self.event = event; self.message = message
        self.scenes = scenes; self.version = version; self.protocolVersion = protocolVersion
        self.streamID = streamID; self.frame = frame; self.info = info
        self.audioPath = audioPath; self.loudness = loudness
    }

    public static func response(_ id: Int, _ result: HostResult) -> HostMessage { HostMessage(id: id, result: result) }
    public static func failure(_ id: Int, _ error: HostError) -> HostMessage { HostMessage(id: id, error: error) }
    public static func ready(scenes: [SceneSummary], version: String) -> HostMessage {
        HostMessage(event: "ready", scenes: scenes, version: version, protocolVersion: HostProtocol.version)
    }
    public static func log(_ text: String) -> HostMessage { HostMessage(event: "log", message: text) }
    public static func warning(_ text: String) -> HostMessage { HostMessage(event: "warning", message: text) }
    /// One pushed playback frame (raw payload follows when `frame.bytes` is set).
    public static func streamFrame(_ streamID: Int, _ frame: HostFrame) -> HostMessage {
        HostMessage(event: "frame", streamID: streamID, frame: frame)
    }
    /// The stream sent its last frame (`message` set when it stopped on an error).
    public static func streamEnd(_ streamID: Int, message: String? = nil) -> HostMessage {
        HostMessage(event: "streamEnd", message: message, streamID: streamID)
    }
    public static func audio(path: String?, loudness: [Float]) -> HostMessage {
        HostMessage(event: "audio", audioPath: path, loudness: loudness)
    }
    public static func infoChanged(_ info: SceneInfo) -> HostMessage { HostMessage(event: "info", info: info) }
}

// MARK: - Export progress

/// One stderr line of `swift-render render … --progress json`:
/// `{"progress":{"frame":120,"total":540,"fps":41.7}}`, every ~10 frames and on the last.
/// Other stderr lines are plain text; skip lines that don't decode.
public struct RenderProgressLine: Codable, Sendable, Equatable {
    public struct Progress: Codable, Sendable, Equatable {
        /// Frames encoded so far (1-based count).
        public var frame: Int
        public var total: Int
        /// Encode throughput so far, frames per second.
        public var fps: Double
        public init(frame: Int, total: Int, fps: Double) { self.frame = frame; self.total = total; self.fps = fps }
    }
    public var progress: Progress
    public init(frame: Int, total: Int, fps: Double) { progress = Progress(frame: frame, total: total, fps: fps) }
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

/// Decodes the host's stdout: JSON lines, where a message whose frame (in
/// `result.frame` or the `frame` event) has `bytes` set is followed by exactly
/// that many raw payload bytes.
public struct HostStreamDecoder: Sendable {
    private var buffer = Data()
    private var pending: (HostMessage, Int)? = nil
    public init() {}

    /// Feed a chunk; returns every complete (message, payload?) in order.
    public mutating func feed(_ chunk: Data) throws -> [(HostMessage, Data?)] {
        buffer.append(chunk)
        var out: [(HostMessage, Data?)] = []
        while true {
            if let (msg, n) = pending {
                guard buffer.count >= n else { break }
                let payload = Data(buffer.prefix(n))
                buffer.removeFirst(n)
                out.append((msg, payload))
                pending = nil
                continue
            }
            guard let nl = buffer.firstIndex(of: 0x0A) else { break }
            let line = Data(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
            if line.isEmpty { continue }
            let msg = try HostWire.decode(HostMessage.self, line: line)
            if let n = (msg.result?.frame ?? msg.frame)?.bytes, n > 0 {
                pending = (msg, n)
            } else {
                out.append((msg, nil))
            }
        }
        return out
    }
}
