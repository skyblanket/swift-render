import IOSurface
import XCTest
import SwiftRenderKit
@testable import SwiftRenderStudio

/// The IOSurface display path: pipe → HostFrameReader → pooled FrameSurface → CGImage.
final class SurfaceTransportTests: XCTestCase {
    /// Writes `chunks` to a pipe from another thread (payloads exceed the pipe buffer),
    /// returning the read end.
    private func pipe(_ chunks: [Data]) -> Int32 {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(Darwin.pipe(&fds), 0)
        let w = fds[1]
        Thread {
            for c in chunks {
                c.withUnsafeBytes { raw in
                    var off = 0
                    while off < raw.count {
                        let n = write(w, raw.baseAddress! + off, raw.count - off)
                        if n <= 0 { break }
                        off += n
                    }
                }
            }
            close(w)
        }.start()
        return fds[0]
    }

    private func frameMessage(width: Int, height: Int, format: String = "bgra8", data: String = "",
                              bytes: Int?) throws -> Data {
        try HostWire.encode(HostMessage(event: "frame", streamID: 7,
                                        frame: HostFrame(t: 0.5, width: width, height: height, format: format,
                                                         data: data, ms: 1, index: 15, bytes: bytes)))
    }

    /// Pixel (x, y) is (b: x & 255, g: y & 255, r: 0x80, a: 0xFF).
    private func pattern(width: Int, height: Int) -> Data {
        var d = Data(count: width * height * 4)
        d.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for y in 0..<height { for x in 0..<width {
                let i = (y * width + x) * 4
                p[i] = UInt8(x & 255); p[i + 1] = UInt8(y & 255); p[i + 2] = 0x80; p[i + 3] = 0xFF
            } }
        }
        return d
    }

    private func check(_ s: FrameSurface, width: Int, height: Int, file: StaticString = #filePath, line: UInt = #line) {
        let base = s.baseAddress.assumingMemoryBound(to: UInt8.self)
        for y in [0, height / 2, height - 1] { for x in [0, 1, width / 2, width - 1] {
            let p = base + y * s.bytesPerRow + x * 4
            XCTAssertEqual([p[0], p[1], p[2], p[3]], [UInt8(x & 255), UInt8(y & 255), 0x80, 0xFF],
                           "pixel \(x),\(y)", file: file, line: line)
        } }
    }

    func testPaddedRowsReadIntoSurfaceAcrossSplitReads() throws {
        let w = 1873, h = 5                                    // 7492 bytes/row, padded in the surface
        let header = try frameMessage(width: w, height: h, bytes: w * h * 4)
        let payload = pattern(width: w, height: h)
        // Header split mid-line, payload straddling the (tiny) scratch buffer.
        let all = header + payload + (try frameMessage(width: w, height: h, bytes: w * h * 4)) + payload
        let cuts = [10, header.count + 3, header.count + 9000, all.count]
        var chunks: [Data] = [], prev = 0
        for c in cuts { chunks.append(all.subdata(in: prev..<c)); prev = c }
        let pool = FrameSurfacePool()
        let reader = HostFrameReader(fd: pipe(chunks), pool: pool, scratchBytes: 64)
        for _ in 0..<2 {
            let (msg, payload) = try XCTUnwrap(try reader.next())
            XCTAssertEqual(msg.frame?.index, 15)
            let s = try XCTUnwrap(payload?.surface)
            XCTAssertGreaterThanOrEqual(s.bytesPerRow, w * 4)
            check(s, width: w, height: h)
            let f = try FrameDecoder.decode(msg.frame!, payload: nil, surface: s, fps: 30)
            XCTAssertEqual(f.width, w); XCTAssertEqual(f.height, h)
            XCTAssertTrue(f.surface === s)
            // The CGImage reads the same pixels.
            let img = f.image
            XCTAssertEqual(img.bytesPerRow, s.bytesPerRow)
        }
        XCTAssertNil(try reader.next())
    }

    func testDataPathAndBase64Passthrough() throws {
        let w = 64, h = 4
        let raw = try frameMessage(width: w, height: h, bytes: w * h * 4) + pattern(width: w, height: h)
        let jpeg = try frameMessage(width: 2, height: 2, format: "jpeg", data: "AAAA", bytes: nil)
        let reader = HostFrameReader(fd: pipe([raw, jpeg]), pool: nil)
        let (_, p1) = try XCTUnwrap(try reader.next())
        XCTAssertEqual(p1?.data, pattern(width: w, height: h))
        let (m2, p2) = try XCTUnwrap(try reader.next())
        XCTAssertNil(p2)
        XCTAssertEqual(m2.frame?.data, "AAAA")
        XCTAssertNil(try reader.next())
    }

    func testTruncatedPayloadThrows() throws {
        let header = try frameMessage(width: 16, height: 16, bytes: 16 * 16 * 4)
        let reader = HostFrameReader(fd: pipe([header, Data(count: 100)]), pool: FrameSurfacePool())
        XCTAssertThrowsError(try reader.next())
    }

    func testPoolRecyclesAndNeverHandsOutAHeldSurface() throws {
        let pool = FrameSurfacePool()
        var a: FrameSurface? = try XCTUnwrap(pool.checkout(width: 32, height: 8))
        let held = try XCTUnwrap(pool.checkout(width: 32, height: 8))
        let aRef = a!.surface
        XCTAssertFalse(aRef === held.surface)
        a = nil                                            // back to the pool
        XCTAssertEqual(pool.freeCount, 1)
        let b = try XCTUnwrap(pool.checkout(width: 32, height: 8))
        XCTAssertTrue(b.surface === aRef, "recycled")
        XCTAssertFalse(b.surface === held.surface, "a held surface is never handed out")
        XCTAssertEqual(pool.created, 2)
        // A new size drops free lists of the old one.
        _ = b
        let c = try XCTUnwrap(pool.checkout(width: 16, height: 16))
        XCTAssertEqual(c.width, 16)
    }

    func testSurfaceImageKeepsSurfaceAlive() throws {
        let pool = FrameSurfacePool()
        var s: FrameSurface? = try XCTUnwrap(pool.checkout(width: 8, height: 8))
        let img = try XCTUnwrap(s?.makeImage())
        s = nil
        XCTAssertEqual(pool.freeCount, 0, "the image still references the surface")
        XCTAssertEqual(img.width, 8)
    }
}
