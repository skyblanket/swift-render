import CoreGraphics
import Foundation
import SwiftRenderKit

// MARK: - Render host abstraction
//
// `HostClient` (a real `<product> serve` child process) and `FakeHostClient`
// (synthetic frames, in-process) both conform, so every controller above this
// line is written and tested against FakeHost and swapped to the real host at
// integration without changes.

/// Wire value of `HostParams.format`.
enum FrameFormat: String, Sendable, CaseIterable {
    case jpeg, png, bgra8
}

/// A frame ready for display. `CGImage` is immutable, so sharing across threads is safe.
struct DecodedFrame: @unchecked Sendable {
    let t: Double
    /// Frame number at the scene's fps.
    let index: Int
    let width: Int
    let height: Int
    let image: CGImage
    /// Host render + encode time, milliseconds.
    let ms: Double
    let format: FrameFormat
    /// Approximate resident cost (decoded pixels).
    var byteCost: Int { width * height * 4 }
    /// Longest edge in pixels: what `maxWidth` caps on the wire (portrait scenes too).
    var edge: Int { max(width, height) }
}

/// `open`'s answer: the scene, plus its first frame when the host rendered one with the
/// reply, and whether clips/knobs/events still follow in an "info" event (`deferProbe`).
struct OpenedScene: Sendable {
    var info: SceneInfo
    var frame: DecodedFrame?
    var probing: Bool
}

/// A response: the result plus the raw payload that followed it (binary frames).
struct HostReply: Sendable {
    var result: HostResult
    var payload: Data?
}

/// How a host process ended.
struct HostTermination: Sendable, Equatable {
    var status: Int32
    /// True when the process died from a signal (crash, SIGKILL) rather than `exit()`.
    var uncaughtSignal: Bool
    /// Last stderr output (fatal error text + backtrace for crashes).
    var stderrTail: String
    /// True when Studio asked it to stop (shutdown/terminate) — not a crash.
    var requested: Bool
}

enum HostClientError: Error, CustomStringConvertible, Equatable {
    case exited(String)
    case timeout(String)
    case protocolError(String)
    case host(HostError)

    var description: String {
        switch self {
        case .exited(let s): return "host exited: \(s)"
        case .timeout(let s): return "host timed out: \(s)"
        case .protocolError(let s): return "protocol error: \(s)"
        case .host(let e): return "\(e.code): \(e.message)"
        }
    }

    var isSuperseded: Bool {
        if case .host(let e) = self { return e.code == "superseded" }
        return false
    }
}

/// A host-pushed frame stream with consumer-granted credits (`stream`/`credit`/`cancel`).
final class HostFrameStream: @unchecked Sendable {
    let id: Int
    let frames: AsyncThrowingStream<DecodedFrame, Error>
    private let grant: @Sendable (Int) -> Void
    private let stop: @Sendable () -> Void

    init(id: Int, frames: AsyncThrowingStream<DecodedFrame, Error>,
         grant: @escaping @Sendable (Int) -> Void, stop: @escaping @Sendable () -> Void) {
        self.id = id; self.frames = frames; self.grant = grant; self.stop = stop
    }

    /// Let the host render `n` more frames.
    func credit(_ n: Int) { if n > 0 { grant(n) } }
    func cancel() { stop() }
}

/// One render host session. Single-consumer `events`; everything else is thread-safe.
protocol RenderHost: AnyObject, Sendable {
    var pid: Int32 { get }
    /// True when the host may answer with raw `bgra8` payloads.
    var supportsBinaryFrames: Bool { get }
    /// Unsolicited events other than stream frames: "log", "warning", "info", "audio".
    var events: AsyncStream<HostMessage> { get }
    /// Waits for the `ready` event (scene list, version).
    func waitUntilReady(timeout: Double) async throws -> HostMessage
    func call(_ method: HostMethod, _ params: HostParams?) async throws -> HostReply
    func frame(t: Double, maxWidth: Int, format: FrameFormat) async throws -> DecodedFrame
    func openStream(from: Double, to: Double?, fps: Int, maxWidth: Int, format: FrameFormat,
                    credits: Int) async throws -> HostFrameStream
    /// `shutdown`, then SIGTERM after 1 s, SIGKILL after 3 s.
    func shutdown() async
    /// Hard stop (hung host).
    func kill()
    func waitForExit() async -> HostTermination
}

extension RenderHost {
    /// Convenience: a stream that returns one credit per frame consumed (fixed window).
    func stream(from: Double, fps: Int, maxWidth: Int, window: Int,
                format: FrameFormat = .jpeg) -> AsyncThrowingStream<DecodedFrame, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let s = try await openStream(from: from, to: nil, fps: fps, maxWidth: maxWidth,
                                                 format: format, credits: window)
                    for try await f in s.frames {
                        continuation.yield(f)
                        s.credit(1)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func open(_ params: HostParams) async throws -> SceneInfo {
        let reply = try await call(.open, params)
        guard let info = reply.result.info else { throw HostClientError.protocolError("open returned no info") }
        return info
    }

    /// `open` that may carry the first frame (`t` set) and a deferred probe. A host that
    /// predates both answers with the full info and no frame; callers fall back to `frame`.
    func openScene(_ params: HostParams) async throws -> OpenedScene {
        let reply = try await call(.open, params)
        guard let info = reply.result.info else { throw HostClientError.protocolError("open returned no info") }
        let frame = reply.result.frame.flatMap { try? FrameDecoder.decode($0, payload: reply.payload, fps: info.fps) }
        return OpenedScene(info: info, frame: frame, probing: reply.result.probing == true)
    }
}

/// Frame number for `t` at `fps` (the frame being shown at that instant).
@inline(__always) func frameIndex(_ t: Double, fps: Int) -> Int {
    Int((t * Double(fps) + 1e-6).rounded(.down))
}

/// `index` itself when it is safe, else the nearest frame in 0...`last` that never crashed
/// the host (later frames first on a tie); nil when every frame did.
func safeFrame(_ index: Int, last: Int = .max, avoiding poisoned: Set<Int>) -> Int? {
    let index = max(0, min(index, last))
    guard poisoned.contains(index) else { return index }
    for d in 1...max(1, poisoned.count + 1) {
        if index + d <= last, !poisoned.contains(index + d) { return index + d }
        if index - d >= 0, !poisoned.contains(index - d) { return index - d }
    }
    return nil
}
