import Darwin
import Foundation
import IOSurface
import SwiftRenderKit

// MARK: - Host stdout reader
//
// Studio's reader thread: JSON header lines found with memchr in a scratch buffer, raw
// payloads read straight to their destination. A bgra8 frame payload lands in a pooled
// IOSurface (row padding handled with readv), so the bytes are copied once — by the
// kernel — between the host's write and the screen. Other payloads (and every payload
// when `pool` is nil) go into a `Data`. Base64 JPEG/PNG frames are unchanged.

enum FramePayload: @unchecked Sendable {
    case bytes(Data)
    case surface(FrameSurface)

    var data: Data? { if case .bytes(let d) = self { return d }; return nil }
    var surface: FrameSurface? { if case .surface(let s) = self { return s }; return nil }
}

enum HostFrameReaderError: Error, Equatable {
    case truncatedPayload(expected: Int, got: Int)
}

final class HostFrameReader {
    private let fd: Int32
    private let pool: FrameSurfacePool?
    private var buf: UnsafeMutableRawPointer
    private var cap: Int
    private var start = 0
    private var end = 0

    /// `SR_PREVIEW_TRANSPORT=data` keeps the Data path (A/B comparisons).
    static var surfacesEnabled: Bool { ProcessInfo.processInfo.environment["SR_PREVIEW_TRANSPORT"] != "data" }

    init(fd: Int32, pool: FrameSurfacePool?, scratchBytes: Int = 1 << 20) {
        self.fd = fd
        self.pool = pool
        self.cap = max(64, scratchBytes)
        self.buf = UnsafeMutableRawPointer.allocate(byteCount: cap, alignment: 16)
    }

    deinit { buf.deallocate() }

    /// The next message and its payload; nil at EOF.
    func next() throws -> (HostMessage, FramePayload?)? {
        while true {
            if end > start, let hit = memchr(buf + start, 0x0A, end - start) {
                let nl = buf.distance(to: hit)
                let lineStart = start
                start = nl + 1
                if nl == lineStart { continue }
                let line = Data(bytes: buf + lineStart, count: nl - lineStart)
                let msg = try HostWire.decode(HostMessage.self, line: line)
                guard let f = msg.result?.frame ?? msg.frame, let n = f.bytes, n > 0 else { return (msg, nil) }
                return (msg, try readPayload(n, frame: f))
            }
            // No full line buffered: compact, grow if a header fills the buffer, read more.
            if start > 0 {
                if end > start { memmove(buf, buf + start, end - start) }
                end -= start; start = 0
            }
            if end == cap { grow(cap * 2) }
            let n = read(fd, buf + end, cap - end)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return nil }
            end += n
        }
    }

    private func grow(_ newCap: Int) {
        let nb = UnsafeMutableRawPointer.allocate(byteCount: newCap, alignment: 16)
        nb.copyMemory(from: buf + start, byteCount: end - start)
        buf.deallocate()
        buf = nb; end -= start; start = 0; cap = newCap
    }

    private func readPayload(_ n: Int, frame f: HostFrame) throws -> FramePayload {
        if let pool, f.format == FrameFormat.bgra8.rawValue, f.width > 0, f.height > 0, n == f.width * f.height * 4,
           let s = pool.checkout(width: f.width, height: f.height) {
            IOSurfaceLock(s.surface, [], nil)
            defer { IOSurfaceUnlock(s.surface, [], nil) }
            try fill(s.baseAddress, rowBytes: f.width * 4, stride: s.bytesPerRow, total: n)
            return .surface(s)
        }
        var d = Data(count: n)
        try d.withUnsafeMutableBytes { raw in
            try fill(raw.baseAddress!, rowBytes: n, stride: n, total: n)
        }
        return .bytes(d)
    }

    /// Writes the next `total` stream bytes into rows of `rowBytes` spaced `stride` apart:
    /// first whatever is already buffered, then straight from the pipe.
    private func fill(_ dst: UnsafeMutableRawPointer, rowBytes: Int, stride: Int, total: Int) throws {
        var off = 0                               // logical offset in the payload
        let have = min(end - start, total)
        while off < have {
            let row = off / rowBytes, col = off % rowBytes
            let k = min(rowBytes - col, have - off)
            (dst + row * stride + col).copyMemory(from: buf + start + off, byteCount: k)
            off += k
        }
        start += have
        if start == end { start = 0; end = 0 }

        if stride == rowBytes {
            while off < total {
                let r = read(fd, dst + off, total - off)
                if r < 0 && errno == EINTR { continue }
                if r <= 0 { throw HostFrameReaderError.truncatedPayload(expected: total, got: off) }
                off += r
            }
            return
        }
        let maxIov = Int(IOV_MAX)
        var iov = [iovec](repeating: iovec(), count: maxIov)
        while off < total {
            var count = 0, o = off
            while o < total, count < maxIov {
                let row = o / rowBytes, col = o % rowBytes
                let k = min(rowBytes - col, total - o)
                iov[count] = iovec(iov_base: dst + row * stride + col, iov_len: k)
                count += 1; o += k
            }
            let r = iov.withUnsafeBufferPointer { readv(fd, $0.baseAddress, Int32(count)) }
            if r < 0 && errno == EINTR { continue }
            if r <= 0 { throw HostFrameReaderError.truncatedPayload(expected: total, got: off) }
            off += r
        }
    }
}
