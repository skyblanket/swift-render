import ImageIO
import SwiftUI
import XCTest
@testable import SwiftRender
@testable import SwiftRenderScenes
@testable import SwiftRenderKit
@testable import SwiftRenderTool

/// A white box whose width is a knob — frames change when the knob does.
private struct KnobBox: RenderScene {
    static let defaultDuration = 2.0
    @MainActor static func body(at t: Double, duration: Double) -> some View {
        let w = Knob.double("box.width", 200, in: 0...1920)
        return ZStack {
            Color.black
            Rectangle().fill(Color.white).frame(width: w, height: 200)
        }
    }
}

/// Declares a knob only in its second half — a probe at t=0 can't see it.
private struct LateKnob: RenderScene {
    static let defaultDuration = 2.0
    @MainActor static func body(at t: Double, duration: Double) -> some View {
        let glow = t > 1 ? Knob.double("late.glow", 0.5, in: 0...1) : 0
        return Color(white: glow)
    }
}

/// Brightness follows the synthesized score: frames depend on the AudioTrack.
private struct ToneLevel: AudioReactiveScene {
    static let defaultDuration = 1.0
    static func soundtrack(duration: Double) -> Score? {
        Score(duration: duration) {
            thump(at: 0.1)
            blip(.midi(76), at: 0.4)
            swell(.midi(64), at: 0.5, duration: 0.4)
        }
    }
    @MainActor static func body(at t: Double, duration: Double, audio: AudioTrack) -> some View {
        Color(white: 0.1 + 0.9 * audio.level(at: t))
    }
}

@MainActor
final class HostTests: XCTestCase {
    private final class Sink {
        var packets: [HostPacket] = []
        var onPacket: ((HostPacket) -> Void)?
    }

    private func tempProject() throws -> Project {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sr-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "// swift-tools-version: 5.10\n".write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        return Project(root: dir)
    }

    private func session(_ project: Project?, sink: Sink = Sink()) -> HostSession {
        KnobStore.shared.set([:])
        return HostSession(runners: ["TimelineDemo": SceneRunner(TimelineDemo.self),
                                     "AudioBars": SceneRunner(AudioBars.self),
                                     "KnobBox": SceneRunner(KnobBox.self),
                                     "LateKnob": SceneRunner(LateKnob.self),
                                     "ToneLevel": SceneRunner(ToneLevel.self)],
                           project: project,
                           schedule: { work in Task { @MainActor in work() } },
                           emit: { p in sink.packets.append(p); sink.onPacket?(p) })
    }

    private func call(_ s: HostSession, _ id: Int, _ method: HostMethod, _ params: HostParams = HostParams()) -> [HostPacket] {
        s.handle(HostRequest(id: id, method: method, params: params))
    }

    private func result(_ packets: [HostPacket], file: StaticString = #filePath, line: UInt = #line) throws -> HostResult {
        let response = try XCTUnwrap(packets.first { $0.message.id != nil }, "no response", file: file, line: line)
        if let e = response.message.error { XCTFail("\(e.code): \(e.message)", file: file, line: line) }
        return try XCTUnwrap(response.message.result, file: file, line: line)
    }

    private func errorCode(_ packets: [HostPacket]) -> String? { packets.first { $0.message.id != nil }?.message.error?.code }

    private func image(_ frame: HostFrame) throws -> CGImage {
        let data = try XCTUnwrap(Data(base64Encoded: frame.data))
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
    }

    /// RGBA8 bytes of any CGImage, for pixel comparisons.
    private func rgba(_ image: CGImage) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: image.width * image.height * 4)
        px.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return px
    }

    // MARK: -

    func testListOpenErrors() throws {
        let s = session(try tempProject())
        XCTAssertEqual(s.readyMessage().event, "ready")
        XCTAssertEqual(s.readyMessage().protocolVersion, HostProtocol.version)
        XCTAssertEqual(try result(call(s, 1, .list)).scenes?.map(\.name), ["AudioBars", "KnobBox", "LateKnob", "TimelineDemo", "ToneLevel"])
        XCTAssertEqual(errorCode(call(s, 2, .frame, HostParams(t: 1))), HostError.Code.noScene)
        XCTAssertEqual(errorCode(call(s, 3, .open, HostParams(scene: "Nope"))), HostError.Code.unknownScene)
        XCTAssertEqual(errorCode(call(s, 4, .open)), HostError.Code.badParams)
        XCTAssertEqual(errorCode(call(s, 5, .open, HostParams(scene: "TimelineDemo", fps: 0))), HostError.Code.badParams)
        XCTAssertEqual(errorCode(call(s, 6, .setProps, HostParams(propsJSON: "{}"))), HostError.Code.noScene)
    }

    func testOpenAndFrameFormats() throws {
        let s = session(try tempProject())
        let info = try XCTUnwrap(result(call(s, 1, .open, HostParams(scene: "TimelineDemo", fps: 30))).info)
        XCTAssertEqual(info.duration, 9.9)
        XCTAssertEqual(info.fps, 30)
        XCTAssertEqual(info.kind, .render)

        let jpeg = try XCTUnwrap(result(call(s, 2, .frame, HostParams(t: 1.0, maxWidth: 480))).frame)
        XCTAssertEqual(jpeg.format, "jpeg")
        XCTAssertEqual(jpeg.index, 30)
        XCTAssertNil(jpeg.bytes)
        let decoded = try image(jpeg)
        XCTAssertEqual([decoded.width, decoded.height], [480, 270])
        XCTAssertEqual([jpeg.width, jpeg.height], [480, 270])

        let png = try XCTUnwrap(result(call(s, 3, .frame, HostParams(t: 1.0, maxWidth: 480, format: "png"))).frame)
        XCTAssertEqual(try image(png).width, 480)

        XCTAssertEqual(errorCode(call(s, 4, .frame, HostParams(t: 1.0, format: "bgra8"))), HostError.Code.badParams,
                       "bgra8 needs binaryFrames on open")
        XCTAssertEqual(errorCode(call(s, 5, .frame, HostParams(t: 1.0, format: "gif"))), HostError.Code.badParams)

        _ = try result(call(s, 6, .open, HostParams(scene: "TimelineDemo", fps: 30, binaryFrames: true)))
        let packets = call(s, 7, .frame, HostParams(t: 1.0, maxWidth: 480, format: "bgra8"))
        let raw = try XCTUnwrap(result(packets).frame)
        XCTAssertEqual(raw.data, "")
        XCTAssertEqual(raw.bytes, 480 * 270 * 4)
        let payload = try XCTUnwrap(packets.first?.payload)
        XCTAssertEqual(payload.count, 480 * 270 * 4)
        // The PNG of the same frame, in BGRA order, is the payload (opaque frame: premultiplication is a no-op).
        let ref = rgba(try image(png))
        var mismatches = 0
        for i in stride(from: 0, to: ref.count, by: 4)
        where payload[i] != ref[i + 2] || payload[i + 1] != ref[i + 1] || payload[i + 2] != ref[i] { mismatches += 1 }
        XCTAssertEqual(mismatches, 0)
    }

    func testFramesAreCoalesced() throws {
        let s = session(try tempProject())
        _ = try result(call(s, 1, .open, HostParams(scene: "TimelineDemo", fps: 30)))
        var out: [HostPacket] = []
        s.process([HostRequest(id: 10, method: .frame, params: HostParams(t: 0.5, maxWidth: 160)),
                   HostRequest(id: 11, method: .frame, params: HostParams(t: 0.6, maxWidth: 160)),
                   HostRequest(id: 12, method: .list),
                   HostRequest(id: 13, method: .frame, params: HostParams(t: 0.7, maxWidth: 160))]) { out.append($0) }
        XCTAssertEqual(out.map { $0.message.id }, [10, 11, 12, 13])
        XCTAssertEqual(out[0].message.error?.code, HostError.Code.superseded)
        XCTAssertEqual(out[1].message.error?.code, HostError.Code.superseded)
        XCTAssertNotNil(out[2].message.result?.scenes)
        XCTAssertEqual(out[3].message.result?.frame?.t, 0.7)
    }

    /// The surviving frame renders at its arrival position: it must not see a later
    /// request's state, and a frame queued before `shutdown` is still rendered.
    func testBatchKeepsArrivalOrderForTheSurvivingFrame() throws {
        let s = session(try tempProject())
        _ = try result(call(s, 1, .open, HostParams(scene: "KnobBox", fps: 30)))
        var out: [HostPacket] = []
        s.process([HostRequest(id: 20, method: .frame, params: HostParams(t: 0.5, maxWidth: 160)),
                   HostRequest(id: 21, method: .list),
                   HostRequest(id: 22, method: .shutdown)]) { out.append($0) }
        XCTAssertEqual(out.map { $0.message.id }, [20, 21, 22], "responses in arrival order")
        XCTAssertEqual(out[0].message.result?.frame?.t, 0.5, "the frame before shutdown renders")
        XCTAssertTrue(s.shutdownRequested)
    }

    func testHugeCreditsAndTimesAreRejectedNotFatal() throws {
        let s = session(try tempProject())
        _ = try result(call(s, 1, .open, HostParams(scene: "TimelineDemo", fps: 30)))
        // t beyond Int range once multiplied by fps used to trap the host.
        for t in [1e18, 1e300, -1e18] {
            XCTAssertEqual(errorCode(call(s, 2, .frame, HostParams(t: t, maxWidth: 160))), HostError.Code.badParams, "t=\(t)")
        }
        // Credits saturate instead of overflowing.
        _ = try result(call(s, 3, .stream, HostParams(maxWidth: 160, from: 0, to: 1, credits: 0)))
        _ = try result(call(s, 4, .credit, HostParams(credits: 2, streamID: 3)))
        _ = try result(call(s, 5, .credit, HostParams(credits: Int.max, streamID: 3)))
        XCTAssertTrue(s.hasStreamWork)
        _ = try result(call(s, 6, .cancel, HostParams(streamID: 3)))
    }

    func testHostFrameMatchesRecorderPNG() throws {
        let size = CGSize(width: 1920, height: 1080)
        let scene = try PreparedScene(name: "TimelineDemo", runner: SceneRunner(TimelineDemo.self), duration: 9.9,
                                      size: size, fps: 30, postFX: true, propsURL: nil, track: .silent)
        let host = try XCTUnwrap(scene.image(at: 2.5, scale: 0.25))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sr-host-ref-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try Recorder(config: .init(fps: 30, size: size, scale: 0.25)).renderPNG(at: 2.5, to: url, duration: 9.9) { t in
            TimelineDemo.body(at: t, duration: 9.9)
        }
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let recorded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertEqual([host.width, host.height], [recorded.width, recorded.height])
        XCTAssertEqual(rgba(host), rgba(recorded), "host frames must be the recorder's pixels")
    }

    func testStreamCreditsCancelAndEnd() throws {
        let s = session(try tempProject())
        _ = try result(call(s, 1, .open, HostParams(scene: "TimelineDemo", fps: 30)))
        XCTAssertEqual(errorCode(call(s, 2, .stream, HostParams(maxWidth: 160, format: "bgra8"))), HostError.Code.badParams)

        _ = try result(call(s, 3, .stream, HostParams(fps: 10, maxWidth: 160, from: 0, to: 0.5, credits: 3)))
        var frames: [HostFrame] = []
        while s.hasStreamWork {
            for p in s.streamStep() {
                XCTAssertEqual(p.message.streamID, 3)
                if let f = p.message.frame { frames.append(f) }
            }
        }
        XCTAssertEqual(frames.map(\.index), [0, 3, 6], "frame index is at the opened fps")
        _ = try result(call(s, 4, .credit, HostParams(credits: 10, streamID: 3)))
        var tail: [HostPacket] = []
        while s.hasStreamWork { tail += s.streamStep() }
        XCTAssertEqual(tail.compactMap { $0.message.frame?.t }, [0.3, 0.4])
        XCTAssertEqual(tail.last?.message.event, "streamEnd")
        XCTAssertNil(tail.last?.message.message)
        XCTAssertFalse(s.hasStreamWork)

        // A new stream replaces the old one; cancel stops it cold.
        _ = try result(call(s, 5, .stream, HostParams(from: 1, credits: 2)))
        let replaced = call(s, 6, .stream, HostParams(from: 2, credits: 2))
        XCTAssertEqual(replaced.first?.message.event, "streamEnd")
        XCTAssertEqual(replaced.first?.message.streamID, 5)
        XCTAssertEqual(s.streamStep().first?.message.streamID, 6)
        _ = try result(call(s, 7, .cancel, HostParams(streamID: 6)))
        XCTAssertFalse(s.hasStreamWork)
        XCTAssertTrue(s.streamStep().isEmpty)
        _ = try result(call(s, 8, .credit, HostParams(credits: 5, streamID: 6)))   // late credit: harmless
        XCTAssertFalse(s.hasStreamWork)
    }

    func testKnobsLiveAndPersisted() throws {
        let project = try tempProject()
        let s = session(project)
        let info = try XCTUnwrap(result(call(s, 1, .open, HostParams(scene: "KnobBox", width: 640, height: 360, fps: 30))).info)
        let knob = try XCTUnwrap(info.knobs.first { $0.key == "box.width" })
        XCTAssertEqual(knob.defaultValue, .number(200))
        XCTAssertEqual(knob.max, 1920)

        let before = try XCTUnwrap(result(call(s, 2, .frame, HostParams(t: 0.5, format: "png"))).frame)
        let dragging = try XCTUnwrap(result(call(s, 3, .setKnobs, HostParams(knobs: ["box.width": .number(500)], reprobe: false))).info)
        XCTAssertEqual(dragging.knobs.first { $0.key == "box.width" }?.value, .number(500))
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.knobsURL(scene: "KnobBox").path), "live-only")
        let after = try XCTUnwrap(result(call(s, 4, .frame, HostParams(t: 0.5, format: "png"))).frame)
        XCTAssertNotEqual(rgba(try image(before)), rgba(try image(after)))

        _ = try result(call(s, 5, .setKnobs, HostParams(knobs: ["box.width": .number(640)], persist: true)))
        XCTAssertEqual(KnobFile.load(project.knobsURL(scene: "KnobBox")), ["box.width": .number(640)])

        // A fresh host reads the persisted file on open.
        let s2 = session(project)
        let reopened = try XCTUnwrap(result(call(s2, 1, .open, HostParams(scene: "KnobBox", width: 640, height: 360))).info)
        XCTAssertEqual(reopened.knobs.first { $0.key == "box.width" }?.value, .number(640))
        _ = try result(call(s2, 2, .setKnobs, HostParams(knobs: [:], persist: true)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.knobsURL(scene: "KnobBox").path), "empty set removes the file")

        // `knobs` on open replaces the project file for this session.
        try KnobFile.save(["box.width": .number(640)], to: project.knobsURL(scene: "KnobBox"))
        let explicit = try XCTUnwrap(result(call(s2, 3, .open, HostParams(scene: "KnobBox", knobs: ["box.width": .number(300)]))).info)
        XCTAssertEqual(explicit.knobs.first { $0.key == "box.width" }?.value, .number(300))
        XCTAssertEqual(KnobStore.shared.values, ["box.width": .number(300)])
    }

    func testFramesReportKnobsTheProbeMissed() throws {
        let s = session(try tempProject())
        let opened = try XCTUnwrap(result(call(s, 1, .open, HostParams(scene: "LateKnob", width: 320, height: 180))).info)
        let early = call(s, 2, .frame, HostParams(t: 0.5, maxWidth: 64))
        XCTAssertFalse(early.contains { $0.message.event == "info" })
        let late = call(s, 3, .frame, HostParams(t: 1.5, maxWidth: 64))
        XCTAssertEqual(late.first?.message.result?.frame?.t, 1.5, "the response comes first")
        let event = late.first { $0.message.event == "info" }
        if opened.knobs.contains(where: { $0.key == "late.glow" }) {
            XCTAssertNil(event, "a probe that already found it sends nothing new")
        } else {
            XCTAssertEqual(event?.message.info?.knobs.map(\.key), ["late.glow"])
        }
        XCTAssertEqual(s.info?.knobs.map(\.key), ["late.glow"])
        XCTAssertFalse(call(s, 4, .frame, HostParams(t: 1.6, maxWidth: 64)).contains { $0.message.event == "info" }, "reported once")
    }

    func testPropsAudioBars() throws {
        let project = try tempProject()
        let s = session(project)
        let props = ##"{"title":"HOST","subtitle":"TEST","barCount":8,"accentHex":"#FF3366","bassPunch":0.2}"##
        let info = try XCTUnwrap(result(call(s, 1, .open, HostParams(scene: "AudioBars", width: 960, height: 540,
                                                                     fps: 30, propsJSON: props))).info)
        XCTAssertEqual(info.kind, .propsAudio)
        XCTAssertEqual(info.propsJSON, props)
        let propsFile = project.cacheDir.appendingPathComponent("props-AudioBars.json")
        XCTAssertEqual(try String(contentsOf: propsFile, encoding: .utf8), props)
        let a = try XCTUnwrap(result(call(s, 2, .frame, HostParams(t: 2, format: "png"))).frame)

        let broken = call(s, 3, .setProps, HostParams(propsJSON: #"{"title":"HOST","barCount":"many"}"#))
        XCTAssertEqual(errorCode(broken), HostError.Code.badParams)
        XCTAssertTrue(broken.first?.message.error?.message.hasPrefix("props:") ?? false)
        XCTAssertEqual(try String(contentsOf: propsFile, encoding: .utf8), props, "a bad payload leaves the props alone")

        let props2 = props.replacingOccurrences(of: "HOST", with: "SECOND").replacingOccurrences(of: "8", with: "24")
        let info2 = try XCTUnwrap(result(call(s, 4, .setProps, HostParams(propsJSON: props2))).info)
        XCTAssertEqual(info2.propsJSON, props2)
        let b = try XCTUnwrap(result(call(s, 5, .frame, HostParams(t: 2, format: "png"))).frame)
        XCTAssertNotEqual(rgba(try image(a)), rgba(try image(b)))
        XCTAssertEqual(errorCode(call(s, 6, .open, HostParams(scene: "TimelineDemo", propsJSON: "{}"))), HostError.Code.badParams)
    }

    func testScoreAudioIsCachedAndAnnounced() async throws {
        let project = try tempProject()
        let sink = Sink()
        let audioReady = expectation(description: "audio event")
        sink.onPacket = { if $0.message.event == "audio" { audioReady.fulfill() } }
        let s = session(project, sink: sink)
        let info = try XCTUnwrap(result(call(s, 1, .open, HostParams(scene: "ToneLevel", width: 320, height: 180, fps: 30))).info)
        XCTAssertNil(info.audioPath, "nothing cached yet: the path arrives with the audio event")
        XCTAssertEqual(info.events.count, 3)
        let silent = try XCTUnwrap(result(call(s, 2, .frame, HostParams(t: 0.15, format: "png"))).frame)

        await fulfillment(of: [audioReady], timeout: 60)
        let event = try XCTUnwrap(sink.packets.first { $0.message.event == "audio" }?.message)
        let path = try XCTUnwrap(event.audioPath)
        XCTAssertTrue(path.hasPrefix(project.cacheDir.appendingPathComponent("audio").path))
        XCTAssertEqual(event.loudness?.count, 50)
        XCTAssertEqual(s.info?.audioPath, path)

        // The cache holds the synthesizer's exact samples, and reactive frames now hear them.
        let (l, r) = ScoreSynth.render(ToneLevel.soundtrack(duration: 1)!)
        let cached = try AudioCache.readFloatWAV(URL(fileURLWithPath: path))
        XCTAssertEqual(cached.left, l)
        XCTAssertEqual(cached.right, r)
        let heard = try XCTUnwrap(result(call(s, 3, .frame, HostParams(t: 0.15, format: "png"))).frame)
        XCTAssertNotEqual(rgba(try image(silent)), rgba(try image(heard)))

        // A new host on the same project starts with the cached path.
        let s2 = session(project)
        let warm = try XCTUnwrap(result(call(s2, 1, .open, HostParams(scene: "ToneLevel", width: 320, height: 180, fps: 30))).info)
        XCTAssertEqual(warm.audioPath, path)
    }

    func testStillAndCheck() throws {
        let project = try tempProject()
        let s = session(project)
        _ = try result(call(s, 1, .open, HostParams(scene: "TimelineDemo", width: 960, height: 540, fps: 30)))
        let still = try XCTUnwrap(result(call(s, 2, .still, HostParams(t: 3, maxWidth: 480, path: "shots/a.png"))).path)
        XCTAssertEqual(still, project.root.appendingPathComponent("shots/a.png").path)
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: still) as CFURL, nil))
        XCTAssertEqual(CGImageSourceCreateImageAtIndex(src, 0, nil)?.width, 480)
        XCTAssertEqual(errorCode(call(s, 3, .still, HostParams(t: 3))), HostError.Code.badParams)

        let check = try result(call(s, 4, .check, HostParams(path: "out/check.png")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(check.path)))
        let report = try XCTUnwrap(check.report)
        XCTAssertTrue(report[0].hasPrefix("scene TimelineDemo · 9.90s · 960×540 @ 30fps"), report[0])
        XCTAssertTrue(report.contains { $0.hasPrefix("audio: none") })
    }

    func testOutputFramingRoundTripsThroughAPipe() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        let output = HostOutput(fd: fds[1])
        let payload = Data((0..<(64 * 1024)).map { UInt8($0 % 251) })   // bigger than one pipe buffer
        let frame = HostFrame(t: 0.5, width: 128, height: 128, format: "bgra8", data: "", ms: 1, index: 15, bytes: payload.count)
        final class Box: @unchecked Sendable { var got: [(HostMessage, Data?)] = [] }
        let box = Box()
        let done = expectation(description: "read")
        let readFD = fds[0]
        DispatchQueue.global().async {
            var decoder = HostStreamDecoder()
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(readFD, &buf, buf.count)
                if n <= 0 { break }
                box.got += (try? decoder.feed(Data(buf[0..<n]))) ?? []
            }
            done.fulfill()
        }
        output.send(HostPacket(.ready(scenes: [], version: "t")))
        output.send(HostPacket(.streamFrame(9, frame), payload: payload))
        output.send(HostPacket(.streamEnd(9)))
        output.flush()
        close(fds[1])
        wait(for: [done], timeout: 10)
        close(fds[0])
        let decoded = box.got
        XCTAssertEqual(decoded.map { $0.0.event }, ["ready", "frame", "streamEnd"])
        XCTAssertEqual(decoded[1].1, payload)
        XCTAssertEqual(decoded[1].0.streamID, 9)
    }

    func testInboxDecodesAndSalvagesIDs() {
        guard case .request(let r) = HostInbox.decode(Data(#"{"id":4,"method":"frame","params":{"t":1.5}}"#.utf8)) else {
            return XCTFail("valid request")
        }
        XCTAssertEqual(r.params?.t, 1.5)
        guard case .malformed(let id, let message) = HostInbox.decode(Data(#"{"id":5,"method":"render"}"#.utf8)) else {
            return XCTFail("unknown method")
        }
        XCTAssertEqual(id, 5)
        XCTAssertTrue(message.contains("unknown method"))
        guard case .malformed(nil, _) = HostInbox.decode(Data("not json".utf8)) else { return XCTFail("garbage") }
    }

    func testCLIKnobsFileReplacesProjectKnobs() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sr-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let saved = sceneRunners
        sceneRunners = ["KnobBox": SceneRunner(KnobBox.self)]
        defer { sceneRunners = saved; KnobStore.shared.set([:]) }
        func frame(_ name: String, knobs: [String: KnobValue]?) async throws -> Data {
            var argv = ["swift-render", "frame", "KnobBox", "--at", "0.5", "--width", "640", "--height", "360",
                        "--out", dir.appendingPathComponent(name).path]
            if let knobs {
                let file = dir.appendingPathComponent("\(name).knobs.json")
                try KnobFile.save(knobs, to: file)
                argv += ["--knobs", file.path]
            }
            try await SwiftRenderTool.run(argv)
            return try Data(contentsOf: dir.appendingPathComponent(name))
        }
        let plain = try await frame("plain.png", knobs: nil)
        let wide = try await frame("wide.png", knobs: ["box.width": .number(600)])
        let same = try await frame("same.png", knobs: ["box.width": .number(200)])
        XCTAssertNotEqual(plain, wide, "--knobs changes the render")
        XCTAssertEqual(plain, same, "an override equal to the default is the default")
    }

    func testCachedMixdownMatchesAudioPlan() throws {
        let score = try XCTUnwrap(ToneLevel.soundtrack(duration: 1))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sr-audio-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let miss = try AudioCache.load(score, in: dir)
        let hit = try AudioCache.load(score, in: dir)
        XCTAssertFalse(miss.cacheHit)
        XCTAssertTrue(hit.cacheHit)
        XCTAssertEqual(hit.fingerprint, miss.fingerprint)
        var scalar = [Float](repeating: 0, count: miss.left.count)
        for i in 0..<scalar.count { scalar[i] = (miss.left[i] + miss.right[i]) * 0.5 }   // AudioPlan's mixdown
        XCTAssertEqual(hit.mono, scalar)
        XCTAssertEqual(miss.mono, scalar)
    }

    func testFingerprintTracksTheScore() {
        let a = Score(duration: 2) { tick(at: 0.5); blip(.midi(70), at: 1) }
        let b = Score(duration: 2) { tick(at: 0.5); blip(.midi(70), at: 1) }
        let c = Score(duration: 2) { tick(at: 0.5); blip(.midi(71), at: 1) }
        XCTAssertEqual(AudioCache.fingerprint(a), AudioCache.fingerprint(b))
        XCTAssertNotEqual(AudioCache.fingerprint(a), AudioCache.fingerprint(c))
        XCTAssertNotEqual(AudioCache.fingerprint(a), AudioCache.fingerprint(Score(duration: 3) { tick(at: 0.5); blip(.midi(70), at: 1) }))
    }

    // MARK: Fast scene switch (deferProbe, first frame on open)

    func testDeferredOpenRepliesWithFirstFrameThenProbes() throws {
        let s = session(try tempProject())
        let packets = call(s, 1, .open, HostParams(scene: "TimelineDemo", width: 320, height: 180, fps: 30,
                                                   t: 1.0, maxWidth: 320, format: "bgra8", binaryFrames: true,
                                                   deferProbe: true))
        let r = try result(packets)
        XCTAssertEqual(r.probing, true, "the probe is deferred")
        let info = try XCTUnwrap(r.info)
        XCTAssertEqual(info.duration, 9.9)
        XCTAssertTrue(info.clips.isEmpty, "clips come with the deferred probe")
        let frame = try XCTUnwrap(r.frame, "the first frame rides on the reply")
        XCTAssertEqual([frame.width, frame.height, frame.index], [320, 180, 30])
        XCTAssertEqual(packets.first { $0.message.id != nil }?.payload?.count, 320 * 180 * 4, "bgra8 payload follows")
        XCTAssertTrue(s.hasDeferredWork)
        XCTAssertTrue(s.runDeferred(now: 0).isEmpty, "not before the grace period")

        let probed = s.runDeferred(now: .infinity)
        let event = try XCTUnwrap(probed.first { $0.message.event == "info" }?.message.info)
        XCTAssertEqual(event.clips.count, 5, "clips arrive in an info event")
        XCTAssertFalse(s.hasDeferredWork)
        XCTAssertEqual(s.info?.clips.count, 5)

        // A revisit (same scene, size, props and knobs) answers complete from the probe cache.
        _ = call(s, 2, .open, HostParams(scene: "KnobBox", width: 320, height: 180, deferProbe: true))
        let again = try result(call(s, 3, .open, HostParams(scene: "TimelineDemo", width: 320, height: 180, fps: 30,
                                                            deferProbe: true)))
        XCTAssertNil(again.probing)
        XCTAssertEqual(again.info?.clips.count, 5)
        XCTAssertNil(again.frame, "no `t`, no frame")
        XCTAssertFalse(s.hasDeferredWork, "the pending KnobBox probe was dropped by the newer open")
    }

    func testOpenWithoutDeferProbeStaysComplete() throws {
        let s = session(try tempProject())
        let r = try result(call(s, 1, .open, HostParams(scene: "TimelineDemo", fps: 30)))
        XCTAssertNil(r.probing)
        XCTAssertEqual(r.info?.clips.count, 5, "old clients get the probe in the reply")
        XCTAssertFalse(s.hasDeferredWork)
    }

    func testBackToBackDeferredOpensOnlyRunTheNewest() throws {
        let s = session(try tempProject())
        var out: [HostPacket] = []
        s.process([HostRequest(id: 1, method: .open, params: HostParams(scene: "KnobBox", deferProbe: true)),
                   HostRequest(id: 2, method: .open, params: HostParams(scene: "TimelineDemo", deferProbe: true))]) { out.append($0) }
        XCTAssertEqual(out.first { $0.message.id == 1 }?.message.error?.code, HostError.Code.superseded)
        XCTAssertEqual(out.first { $0.message.id == 2 }?.message.result?.info?.name, "TimelineDemo")
        XCTAssertEqual(s.info?.name, "TimelineDemo")
        // Without deferProbe (an older client) both still answer.
        out = []
        s.process([HostRequest(id: 3, method: .open, params: HostParams(scene: "KnobBox")),
                   HostRequest(id: 4, method: .open, params: HostParams(scene: "TimelineDemo"))]) { out.append($0) }
        XCTAssertNotNil(out.first { $0.message.id == 3 }?.message.result?.info)
    }

    func testInboxTakeTimesOut() async {
        let inbox = HostInbox()
        let start = Date()
        let items = await inbox.take(wait: true, timeout: 0.05)
        XCTAssertTrue(items.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        inbox.post(.eof)
        let more = await inbox.take(wait: true, timeout: 5)
        XCTAssertEqual(more.count, 1)
    }
}
