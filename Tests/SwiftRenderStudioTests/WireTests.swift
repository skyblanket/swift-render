import CoreGraphics
import XCTest
import SwiftRenderKit
@testable import SwiftRenderStudio

/// Framing and decoding of the host's stdout: JSON lines, binary `bgra8` payloads
/// after their header line, and routing of responses / stream frames / events.
final class WireTests: XCTestCase {
    private func image(_ w: Int, _ h: Int, t: Double = 1.5) -> CGImage {
        FakeFrameArt.draw(t: t, width: w, height: h, scene: "Wire", duration: 10, generation: 1)
    }

    /// One JPEG response, one bgra8 response, one stream frame event and a log — split
    /// into tiny chunks so header lines and payloads straddle reads.
    private func transcript() throws -> (Data, payload: Data) {
        let img = image(64, 36)
        let jpeg = try XCTUnwrap(FrameDecoder.encode(img, format: .jpeg))
        let raw = try XCTUnwrap(FrameDecoder.bgra8Bytes(img))
        var out = Data()
        out += try HostWire.encode(HostMessage.ready(scenes: FakeHostClient.scenes, version: "t"))
        out += try HostWire.encode(HostMessage.response(1, HostResult(frame: HostFrame(
            t: 0.5, width: 64, height: 36, format: "jpeg", data: jpeg.base64EncodedString(), ms: 3, index: 30))))
        out += try HostWire.encode(HostMessage.response(2, HostResult(frame: HostFrame(
            t: 1.5, width: 64, height: 36, format: "bgra8", data: "", ms: 2, index: 90, bytes: raw.count))))
        out += raw
        out += try HostWire.encode(HostMessage(event: "frame", streamID: 3, frame: HostFrame(
            t: 2, width: 64, height: 36, format: "bgra8", data: "", ms: 2, index: 120, bytes: raw.count)))
        out += raw
        out += try HostWire.encode(HostMessage.log("hello\nworld"))
        return (out, raw)
    }

    func testDecoderHandlesArbitraryChunking() throws {
        let (bytes, raw) = try transcript()
        for chunk in [1, 7, 4096, bytes.count] {
            var dec = HostStreamDecoder()
            var got: [(HostMessage, Data?)] = []
            var i = 0
            while i < bytes.count {
                let j = min(bytes.count, i + chunk)
                got += try dec.feed(bytes.subdata(in: i..<j))
                i = j
            }
            XCTAssertEqual(got.count, 5, "chunk \(chunk)")
            XCTAssertEqual(got[0].0.event, "ready")
            XCTAssertNil(got[1].1)
            XCTAssertEqual(got[2].1, raw)
            XCTAssertEqual(got[3].0.streamID, 3)
            XCTAssertEqual(got[3].1, raw)
            XCTAssertEqual(got[4].0.message, "hello\nworld")      // newline escaped inside JSON
        }
    }

    func testBGRA8RoundTripIsPixelExact() throws {
        let img = image(48, 27)
        let raw = try XCTUnwrap(FrameDecoder.bgra8Bytes(img))
        XCTAssertEqual(raw.count, 48 * 27 * 4)
        let back = try FrameDecoder.bgra8(raw, width: 48, height: 27)
        XCTAssertEqual(FrameDecoder.bgra8Bytes(back), raw)
        let f = HostFrame(t: 0.25, width: 48, height: 27, format: "bgra8", data: "", ms: 1, bytes: raw.count)
        let d = try FrameDecoder.decode(f, payload: raw, fps: 60)
        XCTAssertEqual(d.index, 15)                               // index derived from t when absent
        XCTAssertEqual(d.format, .bgra8)
        XCTAssertThrowsError(try FrameDecoder.image(from: f, payload: raw.prefix(100))) { e in
            XCTAssertEqual(e as? FrameDecoderError, .payloadSize(expected: raw.count, got: 100))
        }
        XCTAssertThrowsError(try FrameDecoder.image(from: HostFrame(t: 0, width: 1, height: 1, format: "webp",
                                                                    data: "", ms: 0), payload: nil))
    }

    func testRouterDeliversResponsesStreamsAndEvents() async throws {
        let (bytes, _) = try transcript()
        let router = HostRouter(fps: { 60 })
        let stream = router.registerStream(3)

        async let jpeg: HostReply = withCheckedThrowingContinuation { router.register(1, $0) }
        async let bgra: HostReply = withCheckedThrowingContinuation { router.register(2, $0) }
        try await Task.sleep(for: .milliseconds(20))          // let both register

        var dec = HostStreamDecoder()
        for (m, p) in try dec.feed(bytes) { router.route(m, payload: p) }

        let ready = try await router.waitUntilReady()
        XCTAssertEqual(ready.scenes?.count, FakeHostClient.scenes.count)
        let r1 = try await jpeg, r2 = try await bgra
        XCTAssertEqual(r1.result.frame?.format, "jpeg")
        XCTAssertNil(r1.payload)
        XCTAssertEqual(r2.payload?.count, 64 * 36 * 4)

        var it = stream.makeAsyncIterator()
        let sf = try await it.next()
        XCTAssertEqual(sf?.index, 120)
        XCTAssertEqual(sf?.width, 64)

        var events = router.events.makeAsyncIterator()
        let log = await events.next()
        XCTAssertEqual(log?.event, "log")

        // A dead host fails everything still waiting, and later calls fail fast.
        router.close("exit 0")
        do {
            let _: HostReply = try await withCheckedThrowingContinuation { router.register(9, $0) }
            XCTFail("expected exited")
        } catch {
            XCTAssertEqual(error as? HostClientError, .exited("exit 0"))
        }
    }

    func testFakeServeWireMatchesDecoder() throws {
        let img = image(32, 18)
        let decoded = DecodedFrame(t: 1, index: 60, width: 32, height: 18, image: img, ms: 4, format: .bgra8)
        for fmt in FrameFormat.allCases {
            let (header, payload) = FakeServe.Server.wire(decoded, format: fmt)
            let back = try FrameDecoder.decode(header, payload: payload, fps: 60)
            XCTAssertEqual(back.index, 60)
            XCTAssertEqual(back.width, 32)
            XCTAssertEqual(header.bytes != nil, fmt == .bgra8)
        }
    }
}
