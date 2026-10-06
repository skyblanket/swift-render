import CoreGraphics
import Foundation
import ImageIO
import SwiftRenderKit
import UniformTypeIdentifiers

// MARK: - Host I/O
//
// Plumbing for `swift-render serve` (protocol: SwiftRenderKit/HostProtocol.swift):
// fd ownership, one serial writer, a stdin reader thread feeding an inbox, frame
// encoders, and a crash breadcrumb. No scene knowledge lives here.

/// One protocol line plus the raw payload that must follow it (binary frames).
struct HostPacket: Sendable {
    var message: HostMessage
    var payload: Data?
    init(_ message: HostMessage, payload: Data? = nil) { self.message = message; self.payload = payload }
}

enum HostStdio {
    /// Moves the real stdout to a private close-on-exec fd and points fd 1 at
    /// stderr, so a stray `print` in scene code can't corrupt the stream.
    /// Returns the protocol fd.
    static func claimStdout() -> Int32 {
        fflush(stdout)
        let proto = dup(STDOUT_FILENO)
        precondition(proto >= 0, "dup(stdout) failed")
        _ = fcntl(proto, F_SETFD, FD_CLOEXEC)       // `say`/TTS children must not hold the pipe open
        dup2(STDERR_FILENO, STDOUT_FILENO)
        setvbuf(stdout, nil, _IOLBF, 0)
        signal(SIGPIPE, SIG_IGN)                    // client gone → write returns EPIPE → exit 0
        return proto
    }
}

/// Serial writer: each packet's header line and payload go out back to back.
/// Encoding and the blocking `write(2)` happen off the render thread.
final class HostOutput: @unchecked Sendable {
    private let fd: Int32
    private let queue = DispatchQueue(label: "swift-render.host.output")

    init(fd: Int32) { self.fd = fd }

    func send(_ packet: HostPacket) {
        queue.async { [fd] in
            let line: Data
            do { line = try HostWire.encode(packet.message) }
            catch {
                fputs("[swift-render serve] cannot encode message: \(error)\n", stderr)
                return
            }
            guard Self.writeAll(fd, line), Self.writeAll(fd, packet.payload ?? Data()) else {
                exit(0)                             // reader closed the pipe: the client is gone
            }
        }
    }

    /// Blocks until everything sent so far is written.
    func flush() { queue.sync {} }

    /// `write(2)` until done, retrying partial writes and EINTR. False on EPIPE/any error.
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var p = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                let n = write(fd, p, left)
                if n < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    return false
                }
                p += n; left -= n
            }
            return true
        }
    }
}

/// Everything the render loop consumes, in arrival order.
final class HostInbox: @unchecked Sendable {
    enum Item {
        case request(HostRequest)
        /// A line that didn't decode; `id` when one could be salvaged.
        case malformed(id: Int?, message: String)
        case eof
        /// Main-actor work posted from background jobs (audio ready).
        case main(@MainActor @Sendable () -> Void)
    }

    private let lock = NSLock()
    private var items: [Item] = []
    private var waiter: CheckedContinuation<Void, Never>?

    func post(_ item: Item) {
        lock.lock()
        items.append(item)
        let w = waiter; waiter = nil
        lock.unlock()
        w?.resume()
    }

    /// Everything queued now. With `wait`, suspends until at least one item arrives.
    func take(wait: Bool) async -> [Item] {
        if wait {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in park(c) }
        }
        return drain()
    }

    private func park(_ c: CheckedContinuation<Void, Never>) {
        lock.lock()
        if items.isEmpty { waiter = c; lock.unlock() } else { lock.unlock(); c.resume() }
    }

    private func drain() -> [Item] {
        lock.lock(); defer { lock.unlock() }
        let out = items; items.removeAll(keepingCapacity: true)
        return out
    }

    /// Reads JSON lines from `fd` on a dedicated thread until EOF.
    func startReading(fd: Int32) {
        let thread = Thread { [self] in
            var lines = LineBuffer()
            var buf = [UInt8](repeating: 0, count: 1 << 16)
            while true {
                let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { break }
                for line in lines.append(Data(buf[0..<n])) { post(Self.decode(line)) }
            }
            post(.eof)
        }
        thread.name = "swift-render.host.stdin"
        thread.start()
    }

    static func decode(_ line: Data) -> Item {
        do { return .request(try HostWire.decode(HostRequest.self, line: line)) }
        catch {
            let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            let id = (obj?["id"] as? NSNumber)?.intValue
            let method = obj?["method"] as? String
            let why = method.map { HostMethod(rawValue: $0) == nil ? "unknown method '\($0)'" : "bad params for '\($0)'" }
                ?? "not a request"
            return .malformed(id: id, message: "\(why): \(String(decoding: line.prefix(200), as: UTF8.self))")
        }
    }
}

// MARK: - Frame encoding

enum FrameEncoding {
    /// JPEG/PNG bytes via ImageIO. `quality` applies to JPEG (0…1).
    static func encode(_ image: CGImage, format: String, quality: Double = 0.8) -> Data? {
        let type: UTType = format == "png" ? .png : .jpeg
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let opts: [CFString: Any] = format == "png" ? [:] : [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// "bgra8": rows of width*4 bytes, premultiplied alpha first, little-endian (B,G,R,A in memory), sRGB.
    static func bgra8(_ image: CGImage) -> Data? {
        let w = image.width, h = image.height
        var data = Data(count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
            ctx.setBlendMode(.copy)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? data : nil
    }
}

// MARK: - Crash breadcrumb

/// What the host is rendering, kept in a fixed C buffer so a fatal-signal
/// handler can print it with async-signal-safe `write(2)`, then hand the signal
/// to whatever was installed before (the Swift backtracer, or the default).
enum HostCrashLog {
    private static let capacity = 512
    private static let maxSignal = 32
    nonisolated(unsafe) private static let buffer: UnsafeMutablePointer<CChar> = {
        let p = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
        p.initialize(repeating: 0, count: capacity)
        return p
    }()
    // Indexed by signal number; filled once in `install`, only read in the handler.
    nonisolated(unsafe) private static let previous = UnsafeMutablePointer<sigaction>.allocate(capacity: maxSignal)
    nonisolated(unsafe) private static let headers = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: maxSignal)
    private static let signals: [(Int32, String)] = [(SIGSEGV, "SIGSEGV"), (SIGBUS, "SIGBUS"), (SIGILL, "SIGILL"),
                                                     (SIGTRAP, "SIGTRAP"), (SIGABRT, "SIGABRT"), (SIGFPE, "SIGFPE")]

    /// Record the current activity ("frame Hello t=1.250"); truncated to fit.
    static func note(_ text: String) {
        let bytes = Array(text.utf8.prefix(capacity - 2))
        bytes.withUnsafeBufferPointer { src in
            buffer.withMemoryRebound(to: UInt8.self, capacity: capacity) { dst in
                if let base = src.baseAddress { dst.update(from: base, count: bytes.count) }
                dst[bytes.count] = 0x0A
                dst[bytes.count + 1] = 0
            }
        }
    }

    static func install() {
        note("starting")
        headers.initialize(repeating: nil, count: maxSignal)
        for (sig, name) in signals {
            headers[Int(sig)] = strdup("[swift-render serve] fatal \(name) while: ")
            var action = sigaction()
            action.__sigaction_u.__sa_handler = hostCrashHandler
            sigemptyset(&action.sa_mask)
            action.sa_flags = 0
            sigaction(sig, &action, previous + Int(sig))
        }
    }

    /// Signal-handler body: async-signal-safe calls only.
    fileprivate static func report(_ sig: Int32) {
        guard sig > 0, Int(sig) < maxSignal else { return }
        if let h = headers[Int(sig)] { _ = write(STDERR_FILENO, h, strlen(h)) }
        _ = write(STDERR_FILENO, buffer, strlen(buffer))
        sigaction(sig, previous + Int(sig), nil)
        raise(sig)                                  // delivered once we return, to the previous handler
    }
}

private func hostCrashHandler(_ sig: Int32) {
    HostCrashLog.report(sig)
}
