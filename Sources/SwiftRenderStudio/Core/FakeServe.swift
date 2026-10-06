import Foundation
import SwiftRenderKit

// MARK: - Fake host process
//
//   swift-render-studio --fake-serve [--fake-crash-at t]
//
// FakeHostClient behind the real wire protocol on stdio: JSON-line requests in,
// JSON lines out with `bgra8` frames as header + raw payload, stream frames as
// `frame` events. Studio's `--fake-process-host` mode and the HostClient tests spawn
// it, so the real client (pipes, reader thread, framing, routing, crash detection)
// is exercised end to end without building scenes. A crash writes a Swift-style
// report to stderr and aborts, exactly what the supervisor sees from a real host.

enum FakeServe {
    static func run(_ options: LaunchOptions) -> Never {
        // fd 1 is protocol-only; stray prints go to stderr (same trick as the real host).
        let protoFD = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        signal(SIGPIPE, SIG_IGN)

        let out = WireWriter(fd: protoFD)
        var o = FakeHostClient.Options()
        o.crashAt = options.fakeCrashAt
        o.startupDelay = 0
        o.projectRoot = Project.discover()?.root ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        o.onCrash = { report in
            FileHandle.standardError.write(Data(report.utf8))
            abort()
        }
        let host = FakeHostClient(options: o)
        let server = Server(host: host, out: out)
        out.send(.ready(scenes: FakeHostClient.scenes, version: "fake-serve"))

        let reader = Thread {
            var lines = LineBuffer()
            let cap = 64 * 1024
            let buf = UnsafeMutableRawPointer.allocate(byteCount: cap, alignment: 16)
            while true {
                let n = read(STDIN_FILENO, buf, cap)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                for line in lines.append(Data(bytes: buf, count: n)) { server.handle(line) }
            }
            exit(0)                                     // stdin EOF: never outlive Studio
        }
        reader.name = "fake-serve.stdin"
        reader.start()
        while true { sleep(60) }
    }

    /// Serializes header + payload writes so a payload is never interleaved with another line.
    final class WireWriter: @unchecked Sendable {
        private let fd: Int32
        private let queue = DispatchQueue(label: "fake-serve.out")
        init(fd: Int32) { self.fd = fd }

        func send(_ msg: HostMessage, payload: Data? = nil) {
            guard let line = try? HostWire.encode(msg) else { return }
            queue.async { [fd] in
                Self.writeAll(fd, line)
                if let payload { Self.writeAll(fd, payload) }
            }
        }

        private static func writeAll(_ fd: Int32, _ data: Data) {
            data.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = write(fd, raw.baseAddress! + off, raw.count - off)
                    if n < 0 { if errno == EINTR { continue }; exit(0) }   // Studio went away
                    off += n
                }
            }
        }
    }

    final class Server: @unchecked Sendable {
        let host: FakeHostClient
        let out: WireWriter
        private let lock = NSLock()
        private var streams: [Int: HostFrameStream] = [:]

        init(host: FakeHostClient, out: WireWriter) { self.host = host; self.out = out }

        func handle(_ line: Data) {
            guard let req = try? HostWire.decode(HostRequest.self, line: line) else {
                out.send(HostMessage(event: "warning", message: "malformed request"))
                return
            }
            let p = req.params ?? HostParams()
            switch req.method {
            case .stream:
                Task { await openStream(req.id, p) }
            case .credit:
                if let sid = p.streamID, let s = lock.withLock({ streams[sid] }) { s.credit(p.credits ?? 1) }
                out.send(.response(req.id, HostResult()))
            case .cancel:
                if let sid = p.streamID, let s = lock.withLock({ streams.removeValue(forKey: sid) }) { s.cancel() }
                out.send(.response(req.id, HostResult()))
            case .shutdown:
                out.send(.response(req.id, HostResult()))
                Task { try? await Task.sleep(for: .milliseconds(50)); exit(0) }
            default:
                Task {
                    do {
                        let reply = try await host.call(req.method, p)
                        var result = reply.result
                        // Binary frames: header line with `bytes`, raw payload right after.
                        if let payload = reply.payload { result.frame?.bytes = payload.count }
                        out.send(.response(req.id, result), payload: reply.payload)
                    } catch let HostClientError.host(e) {
                        out.send(.failure(req.id, e))
                    } catch {
                        out.send(.failure(req.id, HostError(code: "internal", message: "\(error)")))
                    }
                }
            }
        }

        private func openStream(_ id: Int, _ p: HostParams) async {
            let format = FrameFormat(rawValue: p.format ?? "jpeg") ?? .jpeg
            do {
                let s = try await host.openStream(from: p.from ?? 0, to: p.to, fps: p.fps ?? 30,
                                                  maxWidth: p.maxWidth ?? 960, format: format, credits: p.credits ?? 4)
                lock.withLock { streams[id] = s }
                out.send(.response(id, HostResult()))
                for try await f in s.frames {
                    let (frame, payload) = Self.wire(f, format: format)
                    out.send(HostMessage(event: "frame", streamID: id, frame: frame), payload: payload)
                }
            } catch let HostClientError.host(e) {
                out.send(.failure(id, e))
            } catch {
                out.send(.failure(id, HostError(code: "internal", message: "\(error)")))
            }
            lock.withLock { _ = streams.removeValue(forKey: id) }
        }

        /// Re-encodes a decoded stream frame the way a real host sends it.
        static func wire(_ f: DecodedFrame, format: FrameFormat) -> (HostFrame, Data?) {
            switch format {
            case .bgra8:
                let bytes = FrameDecoder.bgra8Bytes(f.image) ?? Data()
                return (HostFrame(t: f.t, width: f.width, height: f.height, format: "bgra8", data: "", ms: f.ms,
                                  index: f.index, bytes: bytes.count), bytes)
            case .jpeg, .png:
                let data = FrameDecoder.encode(f.image, format: format) ?? Data()
                return (HostFrame(t: f.t, width: f.width, height: f.height, format: format.rawValue,
                                  data: data.base64EncodedString(), ms: f.ms, index: f.index), nil)
            }
        }
    }
}
