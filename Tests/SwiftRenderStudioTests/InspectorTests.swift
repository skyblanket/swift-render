import XCTest
import SwiftRenderKit
@testable import SwiftRenderStudio

/// Knobs / Props / Info tab logic: value coercion, the paced knob sender, the
/// props JSON tree and its error mapping, contact-sheet hit testing, and the
/// knob round trip through ProjectModel against FakeHost.
@MainActor
final class InspectorTests: XCTestCase {

    // MARK: Coercion

    func testCoerceAcrossKinds() {
        XCTAssertEqual(KnobCoercion.coerce(.number(0.4), to: .double), .number(0.4))
        XCTAssertEqual(KnobCoercion.coerce(.string(" 1,5 "), to: .double), .number(1.5))
        XCTAssertEqual(KnobCoercion.coerce(.string("1e-3"), to: .double), .number(0.001))
        XCTAssertNil(KnobCoercion.coerce(.string("fast"), to: .double))
        XCTAssertNil(KnobCoercion.coerce(.number(.nan), to: .double))
        XCTAssertNil(KnobCoercion.coerce(.bool(true), to: .double))

        XCTAssertEqual(KnobCoercion.coerce(.number(1), to: .bool), .bool(true))
        XCTAssertEqual(KnobCoercion.coerce(.number(0), to: .bool), .bool(false))
        XCTAssertNil(KnobCoercion.coerce(.number(0.5), to: .bool))
        XCTAssertEqual(KnobCoercion.coerce(.string("On"), to: .bool), .bool(true))
        XCTAssertEqual(KnobCoercion.coerce(.string("no"), to: .bool), .bool(false))
        XCTAssertNil(KnobCoercion.coerce(.string("maybe"), to: .bool))

        XCTAssertEqual(KnobCoercion.coerce(.number(2), to: .text), .string("2"))
        XCTAssertEqual(KnobCoercion.coerce(.number(0.25), to: .text), .string("0.25"))
        XCTAssertEqual(KnobCoercion.coerce(.bool(false), to: .text), .string("false"))

        XCTAssertEqual(KnobCoercion.coerce(.string("ffc75c"), to: .color), .string("#FFC75C"))
        XCTAssertNil(KnobCoercion.coerce(.string("orange"), to: .color))
        XCTAssertNil(KnobCoercion.coerce(.number(1), to: .color))
        XCTAssertEqual(KnobCoercion.parse("0.75", kind: .double), .number(0.75))
    }

    func testHexColors() {
        XCTAssertEqual(KnobCoercion.normalizeHex("#fc5"), "#FFCC55")
        XCTAssertEqual(KnobCoercion.normalizeHex("#FFC75CFF"), "#FFC75C", "opaque alpha is dropped")
        XCTAssertEqual(KnobCoercion.normalizeHex("ffc75c80"), "#FFC75C80")
        XCTAssertEqual(KnobCoercion.normalizeHex("#f008"), "#FF000088")
        XCTAssertNil(KnobCoercion.normalizeHex("#12345"))
        XCTAssertNil(KnobCoercion.normalizeHex("#GGGGGG"))

        let c = try! XCTUnwrap(KnobCoercion.rgba("#FFC75C80"))
        XCTAssertEqual(c.r, 1, accuracy: 1e-9)
        XCTAssertEqual(c.g, 199.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(c.a, 128.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(KnobCoercion.hex(r: c.r, g: c.g, b: c.b, a: c.a), "#FFC75C80")
        XCTAssertEqual(KnobCoercion.hex(r: 1, g: 0, b: 0.5), "#FF0080")
        XCTAssertEqual(KnobCoercion.hex(r: 2, g: -1, b: 0), "#FF0000", "clamped")
        // Through SwiftUI's Color/NSColor and back.
        XCTAssertEqual(KnobColorControl.hex(KnobColorControl.color("#5CC8FF")), "#5CC8FF")
    }

    func testSliderStepsSnapAndFormat() {
        XCTAssertEqual(KnobCoercion.step(for: 0...2), 0.02, accuracy: 1e-12)
        XCTAssertEqual(KnobCoercion.step(for: 0...1), 0.01, accuracy: 1e-12)
        XCTAssertEqual(KnobCoercion.step(for: -10...20), 0.5, accuracy: 1e-12)
        XCTAssertEqual(KnobCoercion.step(for: 0...1000), 10, accuracy: 1e-12)
        XCTAssertEqual(KnobCoercion.decimals(for: 0.02), 2)
        XCTAssertEqual(KnobCoercion.decimals(for: 0.5), 1)
        XCTAssertEqual(KnobCoercion.decimals(for: 10), 0)
        XCTAssertEqual(KnobCoercion.snap(0.1 + 0.2, step: 0.01), 0.3, "no binary noise in knobs files")
        XCTAssertEqual(KnobCoercion.snap(0.4012345, step: 0.02), 0.4)
        XCTAssertEqual(KnobCoercion.snap(-2.26, step: 0.5), -2.5)
        XCTAssertEqual(KnobCoercion.format(1), "1")
        XCTAssertEqual(KnobCoercion.format(0.4), "0.4")
        XCTAssertEqual(KnobCoercion.format(-2.25), "-2.25")
    }

    func testNormalizedDropsDefaultsAndCoerces() {
        let knobs = [
            KnobInfo(key: "a", kind: .double, defaultValue: .number(1), value: .number(1)),
            KnobInfo(key: "b", kind: .bool, defaultValue: .bool(false), value: .bool(false)),
            KnobInfo(key: "c", kind: .color, defaultValue: .string("#FFFFFF"), value: .string("#FFFFFF")),
        ]
        let live: [String: KnobValue] = ["a": .number(1), "b": .string("on"), "c": .string("ffffff"),
                                         "unseen": .number(3)]
        XCTAssertEqual(KnobCoercion.normalized(live, knobs: knobs), ["b": .bool(true), "unseen": .number(3)])
    }

    // MARK: Source scan

    func testSourceScanFindsDeclarationsWithLines() {
        let src = """
        let a = Knob.double("title.delay", 0.3, in: 0...2)
        if Knob.bool("debug.safe", false) {
            let o = Knob.double( "debug.opacity", 0.5)
        }
        let again = Knob.double("title.delay", 9)
        let t = Knob.text("say \\"hi\\"", "x")
        """
        let d = KnobSourceScan.declarations(in: src)
        XCTAssertEqual(d.map(\.key), ["title.delay", "debug.safe", "debug.opacity", "say \\\"hi\\\""])
        XCTAssertEqual(d.map(\.line), [1, 2, 3, 6])
        XCTAssertEqual(d[1].kind, .bool)
        let known = [KnobInfo(key: "title.delay", kind: .double, defaultValue: .number(0.3), value: .number(0.3)),
                     KnobInfo(key: "debug.safe", kind: .bool, defaultValue: .bool(false), value: .bool(false))]
        XCTAssertEqual(KnobSourceScan.unreached(in: src, known: known).map(\.key).first, "debug.opacity")
    }

    // MARK: Paced sending

    /// 100 slider moves over 100 ms → a handful of sends at ≤ 30 Hz, one in flight at a
    /// time, always the newest values, and the release (re-probe) last.
    func testSenderPacesDragsAndAlwaysDeliversRelease() async {
        var clock = 0.0
        var sent: [(value: Double, dragging: Bool, at: Double)] = []
        var inFlight = 0, maxInFlight = 0
        // A fake sleep that waits for the test's clock (spinning a bounded number of turns
        // once nothing advances it any more), so timers don't make time run faster.
        let sleep: (Double) async -> Void = { d in
            let target = clock + d
            var spins = 0
            while clock < target, spins < 2000 { await Task.yield(); spins += 1 }
            clock = max(clock, target)
        }
        let sender = KnobSender(interval: 1.0 / 30, now: { clock }, sleep: sleep) { v, dragging in
            inFlight += 1; maxInFlight = max(maxInFlight, inFlight)
            sent.append((v["k"]?.doubleValue ?? -1, dragging, clock))
            clock += 0.004                        // the host takes 4 ms
            await Task.yield()
            inFlight -= 1
        }
        for i in 0..<100 {
            sender.submit(["k": .number(Double(i))], dragging: true)
            clock += 0.001
            await Task.yield()
        }
        sender.submit(["k": .number(100)], dragging: false)
        await sender.drain()

        let drags = sent.filter(\.dragging)
        XCTAssertGreaterThanOrEqual(drags.count, 2)
        XCTAssertLessThanOrEqual(drags.count, 6, "≈ 100 ms at 30 Hz, not one per mouse move")
        for (a, b) in zip(drags, drags.dropFirst()) {
            // `at` is read when the send task runs, up to a 1 ms test tick after it was paced.
            XCTAssertGreaterThanOrEqual(b.at - a.at, 1.0 / 30 - 0.002, "drag sends are ≥ 1/30 s apart")
            XCTAssertGreaterThan(b.value, a.value, "always the newest value")
        }
        XCTAssertEqual(sent.last?.value, 100)
        XCTAssertEqual(sent.last?.dragging, false)
        XCTAssertEqual(sent.filter { !$0.dragging }.count, 1)
        XCTAssertEqual(maxInFlight, 1)
        XCTAssertFalse(sender.isBusy)
    }

    /// A drag that lands while a release is queued must not cancel the release's re-probe.
    func testQueuedReleaseKeepsItsReprobe() async {
        var sent: [Bool] = []
        var gate: CheckedContinuation<Void, Never>?
        let sender = KnobSender(interval: 0, now: { 0 }, sleep: { _ in await Task.yield() }) { _, dragging in
            sent.append(dragging)
            if sent.count == 1 { await withCheckedContinuation { gate = $0 } }   // hold the first send
        }
        sender.submit(["k": .number(1)], dragging: true)
        await waitUntil(2, "first send") { gate != nil }
        sender.submit(["k": .number(2)], dragging: false)
        sender.submit(["k": .number(3)], dragging: true)
        gate?.resume()
        await sender.drain()
        XCTAssertEqual(sent, [true, false])
    }

    // MARK: Props tree

    struct Stat: Codable { var label: String; var value: Double; var unit: String }
    struct Props: Codable { var title: String; var speed: Double; var showGrid: Bool; var count: Int
        var stats: [Stat]; var tags: [String]; var meta: [String: String] }

    func testPrettyMatchesJSONEncoderAndKeepsLiterals() throws {
        let p = Props(title: "Launch \"Day\"\n", speed: 0.85, showGrid: true, count: 120,
                      stats: [Stat(label: "fps", value: 60, unit: ""), Stat(label: "ms", value: 2.5, unit: "ms")],
                      tags: [], meta: [:])
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let template = String(decoding: try enc.encode(p), as: UTF8.self)
        let doc = try JSONValue.parse(template)
        XCTAssertEqual(doc.pretty, template, "a form round trip changes nothing")
        XCTAssertEqual(doc[PropsPath(codingPath: "count")], .number("120"), "ints stay ints")
        XCTAssertEqual(doc[PropsPath(codingPath: "stats.1.value")], .number("2.5"))
        XCTAssertEqual(doc[PropsPath(codingPath: "title")], .string("Launch \"Day\"\n"))

        // Hand-written key order survives (JSONSerialization would sort it).
        let hand = try JSONValue.parse(#"{"z": 1, "a": [true, null, "x"], "m": {"k": -0.5e2}}"#)
        guard case .object(let members) = hand else { return XCTFail() }
        XCTAssertEqual(members.map(\.key), ["z", "a", "m"])
        XCTAssertEqual(try JSONValue.parse(hand.pretty), hand)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(hand.pretty.utf8)))
    }

    func testParseErrorsCarryLineAndColumn() {
        XCTAssertThrowsError(try JSONValue.parse("{\n  \"a\" : 1,\n  \"b\" : tru\n}")) { e in
            let p = e as? JSONParseError
            XCTAssertEqual(p?.line, 3)
            XCTAssertEqual(p?.column, 9)
        }
        XCTAssertThrowsError(try JSONValue.parse("[1, 2,]"))
        XCTAssertThrowsError(try JSONValue.parse("{\"a\": 01}"))
        XCTAssertThrowsError(try JSONValue.parse("{} x"))
        XCTAssertEqual(try JSONValue.parse(#""é😀""#), .string("é😀"))
    }

    func testEditingTheTree() throws {
        var doc = try JSONValue.parse(#"{"title": "A", "stats": [{"v": 1}, {"v": 2}], "empty": []}"#)
        XCTAssertTrue(doc.set(PropsPath(codingPath: "stats.1.v"), .number("5")))
        XCTAssertFalse(doc.set(PropsPath(codingPath: "stats.7.v"), .number("5")))
        XCTAssertTrue(doc.appendClone(at: PropsPath(codingPath: "stats")))
        XCTAssertEqual(doc[PropsPath(codingPath: "stats.2.v")], .number("5"), "a new element copies the last")
        XCTAssertFalse(doc.appendClone(at: PropsPath(codingPath: "empty")))
        XCTAssertTrue(doc.remove(at: PropsPath(codingPath: "stats.0")))
        XCTAssertEqual(doc[PropsPath(codingPath: "stats")], .array([.object([JSONMember(key: "v", value: .number("5"))]),
                                                                    .object([JSONMember(key: "v", value: .number("5"))])]))
        XCTAssertEqual(doc.nearestExisting(PropsPath(codingPath: "stats.1.unit")).description, "stats.1")
    }

    func testRowsAndDefaultExpansion() throws {
        let big = (0..<400).map { "\($0)" }.joined(separator: ",")
        let doc = try JSONValue.parse(##"{"title": "#FFC75C", "logo": "assets/logo.png", "sx": [\##(big)], "stats": [{"a": 1}]}"##)
        let open = doc.defaultExpanded()
        XCTAssertFalse(open.contains(PropsPath(codingPath: "sx")), "a 400-sample array stays shut")
        XCTAssertTrue(open.contains(PropsPath(codingPath: "stats")))
        let rows = doc.rows(expanded: open)
        XCTAssertEqual(rows.map { $0.path.description }, ["title", "logo", "sx", "stats", "stats.0"])
        XCTAssertEqual(rows[0].kind, .color)
        XCTAssertEqual(rows[1].kind, .media)
        XCTAssertEqual(rows[4].depth, 1)
        XCTAssertEqual(doc.rows(expanded: open.union([PropsPath(codingPath: "sx")])).count, 405)
    }

    /// The host's messages come from `DecodingError` coding paths ("Index 1" for array
    /// elements); produce real ones and map them back to fields.
    func testHostDecodeErrorsMapToFields() {
        func hostMessage(_ json: String) -> String {
            // Same wording as SceneRunner.describe + PropsError.shortDescription.
            func path(_ c: [CodingKey]) -> String { c.map(\.stringValue).joined(separator: ".") }
            do { _ = try JSONDecoder().decode(Props.self, from: Data(json.utf8)); return "" }
            catch DecodingError.keyNotFound(let k, let ctx) { return "props: missing key '\(k.stringValue)' at \(path(ctx.codingPath))" }
            catch DecodingError.typeMismatch(let t, let ctx) { return "props: expected \(t) at \(path(ctx.codingPath))" }
            catch DecodingError.valueNotFound(let t, let ctx) { return "props: null for \(t) at \(path(ctx.codingPath))" }
            catch { return "props: \(error)" }
        }
        let base = #""title":"x","speed":1,"showGrid":true,"count":1,"tags":[],"meta":{}"#
        let mismatch = PropsIssue.parse(hostMessage("{\(base),\"stats\":[{\"label\":\"a\",\"value\":1,\"unit\":\"\"},{\"label\":\"b\",\"value\":\"zero\",\"unit\":\"\"}]}"))
        XCTAssertEqual(mismatch.message, "expected Double")
        XCTAssertEqual(mismatch.path?.description, "stats.1.value")

        let missing = PropsIssue.parse(hostMessage("{\(base),\"stats\":[{\"label\":\"a\",\"value\":1}]}"))
        XCTAssertEqual(missing.message, "missing key “unit”")
        XCTAssertEqual(missing.path?.description, "stats.0")

        let null = PropsIssue.parse(hostMessage(#"{"title":null,"speed":1,"showGrid":true,"count":1,"tags":[],"meta":{},"stats":[]}"#))
        XCTAssertEqual(null.path?.description, "title")
        XCTAssertTrue(null.message.contains("got null"))

        XCTAssertNil(PropsIssue.parse("props: invalid JSON: Unexpected character").path)
    }

    func testVariantFileNames() {
        XCTAssertEqual(InspectorController.variantFileName("Launch – EU (v2)"), "Launch-EU-v2")
        XCTAssertEqual(InspectorController.variantFileName("../../etc"), "etc")
        XCTAssertEqual(InspectorController.variantFileName("  "), "")
    }

    // MARK: Contact sheet

    /// Matches composeContactSheet: 384×216 thumbs, 4 px gaps, 22 px labels.
    func testContactSheetHitTesting() {
        let sheet = CGSize(width: 4 * 384 + 5 * 4, height: 4 * (216 + 22) + 5 * 4)
        XCTAssertEqual(ContactSheetGeometry.cellRect(5, sheet: sheet), CGRect(x: 392, y: 246, width: 384, height: 216))
        XCTAssertEqual(ContactSheetGeometry.cell(at: CGPoint(x: 392 + 10, y: 246 + 10), sheet: sheet), 5)
        XCTAssertEqual(ContactSheetGeometry.cell(at: CGPoint(x: 392 + 10, y: 246 + 216 + 10), sheet: sheet), 5, "the label belongs to its cell")
        XCTAssertNil(ContactSheetGeometry.cell(at: CGPoint(x: 390, y: 300), sheet: sheet), "gaps aren't cells")
        XCTAssertEqual(ContactSheetGeometry.cell(at: CGPoint(x: sheet.width - 5, y: sheet.height - 5), sheet: sheet), 15)
        XCTAssertEqual(ContactSheetGeometry.time(cell: 0, duration: 16), 0.5)
        XCTAssertEqual(ContactSheetGeometry.time(cell: 15, duration: 16), 15.5)
        XCTAssertEqual(ContactSheetGeometry.cell(for: 15.9, duration: 16), 15)
        XCTAssertEqual(ContactSheetGeometry.cell(for: 16, duration: 16), 15)
        XCTAssertNil(ContactSheetGeometry.cell(for: 17, duration: 16))
    }

    func testLaunchOptions() {
        let o = LaunchOptions.parse([".", "--scene", "KnobLab", "--knob", "title.scale=1.3", "--knob", "headline=a=b",
                                     "--props", "v.json", "--check"])
        XCTAssertEqual(o.knobs, ["title.scale": "1.3", "headline": "a=b"])
        XCTAssertEqual(o.propsFile, "v.json")
        XCTAssertTrue(o.runCheck)
        XCTAssertEqual(o.scene, "KnobLab")
    }

    func testCheckReportHelpers() {
        XCTAssertEqual(InfoTab.levels("audio: 25.20s · peak -0.7 dBFS · RMS -10.7 dBFS · clipped samples 0"),
                       "peak -0.7 dBFS · RMS -10.7 dBFS")
        XCTAssertEqual(ReportLine.stripWarning("⚠︎ clipping — lower amps"), "clipping — lower amps")
    }

    // MARK: Through ProjectModel + FakeHost

    /// Live set → host gets the complete set; reset sends the set without the key (back to
    /// default, not "unchanged"); Save writes defaults-free JSON; Revert restores it.
    func testKnobRoundTripThroughModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sr-insp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var options = LaunchOptions()
        options.fakeHost = true
        options.scene = "LaunchFilm"
        let model = ProjectModel(root: root, options: options)
        await model.start()
        await waitUntil(10, "scene open") { model.info != nil }
        defer { Task { await model.shutdown() } }
        let insp = model.inspector
        let scale = try XCTUnwrap(model.info?.knobs.first { $0.key == "logo.scale" })
        let grain = try XCTUnwrap(model.info?.knobs.first { $0.key == "grain" })

        for v in stride(from: 1.0, through: 1.5, by: 0.05) { insp.set(scale, .number(v), dragging: true) }
        insp.set(scale, .number(1.5))
        insp.set(grain, .bool(false))
        await insp.knobs.drain()
        XCTAssertLessThan(insp.knobs.sentCount, 8, "drags were paced")
        XCTAssertEqual(model.host.info?.knobs.first { $0.key == "logo.scale" }?.value, .number(1.5))
        XCTAssertEqual(model.info?.knobs.first { $0.key == "grain" }?.value, .bool(false), "release adopts re-probed info")
        XCTAssertTrue(insp.isDirty)
        XCTAssertTrue(insp.differsFromFile("grain"))

        insp.reset(grain)
        await insp.knobs.drain()
        XCTAssertEqual(model.host.info?.knobs.first { $0.key == "grain" }?.value, .bool(true), "reset reached the host")
        XCTAssertEqual(model.host.info?.knobs.first { $0.key == "logo.scale" }?.value, .number(1.5), "others kept")

        insp.set(grain, .bool(true))          // equal to the default: not worth saving
        insp.saveKnobs()
        XCTAssertEqual(KnobFile.load(model.project.knobsURL(scene: "LaunchFilm")), ["logo.scale": .number(1.5)])
        XCTAssertFalse(insp.isDirty)

        insp.set(scale, .number(0.7))
        await insp.knobs.drain()
        insp.revertKnobs()
        await insp.knobs.drain()
        XCTAssertEqual(model.knobValues, ["logo.scale": .number(1.5)])
        XCTAssertEqual(model.host.info?.knobs.first { $0.key == "logo.scale" }?.value, .number(1.5))
        XCTAssertFalse(insp.isDirty)
    }

    func testPropsApplyAndVariants() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sr-insp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var options = LaunchOptions()
        options.fakeHost = true
        options.scene = "JETRAYChase"
        let model = ProjectModel(root: root, options: options)
        await model.start()
        await waitUntil(10, "scene open") { model.info?.propsJSON != nil }
        defer { Task { await model.shutdown() } }
        let insp = model.inspector
        insp.syncProps()
        XCTAssertFalse(insp.propsEdited)
        insp.setField(PropsPath(codingPath: "speed"), .number("1.25"))
        XCTAssertTrue(insp.propsEdited)
        await insp.applyProps()
        XCTAssertNil(insp.propsIssue)
        XCTAssertFalse(insp.propsEdited)
        XCTAssertEqual(try JSONValue.parse(try XCTUnwrap(model.propsJSON))[PropsPath(codingPath: "speed")], .number("1.25"))

        let url = try XCTUnwrap(insp.saveVariant(named: "fast cut"))
        XCTAssertEqual(url.path, model.project.root.appendingPathComponent(".swift-render/props/JETRAYChase/fast-cut.json").path)
        XCTAssertEqual(insp.variants.map(\.lastPathComponent), ["fast-cut.json"])

        insp.switchProps(to: .json)
        insp.propsText = "{ \"speed\": }"
        XCTAssertNotNil(insp.propsSyntax)
        XCTAssertNil(insp.editorJSON, "Apply is off until the JSON parses")
        insp.switchProps(to: .form)
        XCTAssertEqual(insp.propsMode, .json, "can't leave JSON mode with a syntax error")
        insp.revertProps()
        XCTAssertNil(insp.propsSyntax)
        XCTAssertFalse(insp.propsEdited)
    }
}
