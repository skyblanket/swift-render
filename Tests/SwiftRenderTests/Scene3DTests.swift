import SwiftUI
import XCTest
import SceneKit
import simd
@testable import SwiftRender
@testable import SwiftRenderScenes

/// Scene3D: SceneKit rendered offscreen, driven only by t.
@MainActor
final class Scene3DTests: XCTestCase {
    override func setUp() async throws {
        guard Engine3D.usableDevice() != nil else { throw XCTSkip("Scene3D needs a real Metal GPU (none, or a VM's paravirtual one)") }
    }

    // MARK: helpers

    struct Pixels {
        let width: Int, height: Int
        let bytes: [UInt8]   // RGBA premultiplied
        func at(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            let i = (y * width + x) * 4
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]), Int(bytes[i + 3]))
        }
    }

    func pixels(_ cg: CGImage) -> Pixels {
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        bytes.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8,
                                bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setBlendMode(.copy)
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        return Pixels(width: cg.width, height: cg.height, bytes: bytes)
    }

    /// Peak signal-to-noise ratio in dB (∞ when identical).
    func psnr(_ a: Pixels, _ b: Pixels) -> Double {
        precondition(a.bytes.count == b.bytes.count)
        var sum = 0.0
        for i in 0..<a.bytes.count {
            let d = Double(a.bytes[i]) - Double(b.bytes[i]); sum += d * d
        }
        let mse = sum / Double(a.bytes.count)
        return mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
    }

    /// A small product shot exercising most of the pipeline (PBR, IBL, shadows, DOF, bloom,
    /// a SwiftUI texture, text).
    func productShot(_ t: Double, id: String = "test.product") -> Scene3D {
        let center: Vec3 = [0, 0.08, 0]
        let cam = Camera3D.orbit(target: center, distance: 0.45, azimuth: Motion3D.turntable(t, degreesPerSecond: 20),
                                 elevation: 10, fov: 30).focused(on: center, fStop: 2.8)
        return Scene3D(camera: cam, background: .color(Color(white: 0.1)), effects: .cinematic, id: id) {
            Slab3D(width: 0.07, height: 0.145, depth: 0.008, cornerRadius: 0.011,
                   screen: .screen(.view(width: 120, height: 240) {
                       ZStack { Color.blue; Text("\(Int(t * 10))").font(.system(size: 40, weight: .bold)) }
                   }))
                .material(.metal(Color(white: 0.7), roughness: 0.3))
                .rotation(y: Motion3D.oscillate(t, degrees: 20, period: 3))
                .position(center)
            Text3D("3D", size: 0.03, depth: 0.006).material(.plastic(.orange)).position(0.06, 0.02, 0.03)
            Sphere3D(radius: 0.02).material(.emissive(.white, intensity: 3)).position(-0.07, 0.02, -0.05)
            Floor3D(material: .matte(Color(white: 0.2)))
            Light3D.studioRig(target: center, size: 0.15)
        }
    }

    func render(_ s: Scene3D, _ w: CGFloat = 320, _ h: CGFloat = 180, scale: CGFloat = 1) -> Pixels {
        guard let cg = s.image(size: CGSize(width: w, height: h), scale: scale) else {
            XCTFail("Scene3D produced no image"); return Pixels(width: 0, height: 0, bytes: [])
        }
        return pixels(cg)
    }

    // MARK: determinism

    func testSameTimeTwiceIsIdentical() {
        for t in [0.0, 0.7, 2.3] {
            let a = render(productShot(t))
            let b = render(productShot(t))
            XCTAssertTrue(a.bytes == b.bytes, "t=\(t): re-render through the cached renderer differs (PSNR \(psnr(a, b)) dB)")
        }
    }

    /// A frame must not depend on which frames were rendered before it (scrubbing, `--range`,
    /// `--jobs` chunks all start at arbitrary frames).
    func testFrameIsIndependentOfHistory() {
        let first = render(productShot(1.0))
        _ = render(productShot(4.5))
        _ = render(productShot(0.1))
        let again = render(productShot(1.0))
        XCTAssertTrue(first.bytes == again.bytes, "history changed the frame (PSNR \(psnr(first, again)) dB)")
    }

    /// Re-creating the SceneKit scene inside the same process (cache eviction, Studio hot
    /// reload) is not bit-exact: SceneKit seeds sampling noise for soft shadows, SSAO and
    /// depth of field per scene instance and offers no way to fix the seed. Measured on Apple
    /// silicon: ≈80–inf dB without SSAO, ≈49 dB with SSAO + depth of field. A fresh process
    /// is bit-identical to any other fresh process (that is what `--jobs` relies on).
    func testRebuiltSceneStaysWithinPSNRBound() {
        for fx in [Effects3D.cinematic, Effects3D()] {
            var shot = productShot(1.0, id: "test.rebuild")
            shot.effects = fx
            let warm = render(shot)
            Scene3D.purgeCaches()
            let cold = render(shot)
            let p = psnr(warm, cold)
            XCTAssertGreaterThanOrEqual(p, 45, "rebuilt scene drifted too far (PSNR \(p) dB, AO \(fx.ambientOcclusion))")
        }
    }


    func testDifferentTimesDiffer() {
        XCTAssertFalse(render(productShot(0.5)).bytes == render(productShot(1.5)).bytes)
    }

    /// Through the Recorder (ImageRenderer → displayScale) the 3D layer renders at the frame's
    /// real pixel size, and the whole frame stays deterministic.
    func testRecorderFramesAtScaleAreDeterministic() throws {
        let rec = Recorder(config: .init(fps: 30, size: CGSize(width: 320, height: 180), scale: 2))
        let a = try rec.renderImage(at: 1.2, postFX: false) { t in Showcase3D.body(at: t, duration: 10) }
        XCTAssertEqual(Engine3D.shared.lastPixelSize, CGSize(width: 640, height: 360),
                       "Scene3D should render at layout size × display scale")
        let b = try rec.renderImage(at: 1.2, postFX: false) { t in Showcase3D.body(at: t, duration: 10) }
        XCTAssertEqual(a.width, 640)
        XCTAssertTrue(pixels(a).bytes == pixels(b).bytes)
    }

    // MARK: features

    func testSwiftUIViewTexture() {
        // An unlit plane filling the view shows the SwiftUI view's pixels.
        let s = Scene3D(camera: Camera3D(position: [0, 0, 1], target: .zero, fov: 40), environment: .none,
                        background: .color(.black), effects: Effects3D(hdr: false), id: "test.texture") {
            Plane3D(width: 4, height: 4).material(.unlit(.view(width: 64, height: 64) {
                HStack(spacing: 0) { Color(red: 1, green: 0, blue: 0); Color(red: 0, green: 1, blue: 0) }
            }))
        }
        let px = render(s, 200, 200)
        let left = px.at(60, 100), right = px.at(140, 100)
        XCTAssertGreaterThan(left.r, 200); XCTAssertLessThan(left.g, 40)
        XCTAssertGreaterThan(right.g, 200); XCTAssertLessThan(right.r, 40)
    }

    func testTransparentBackground() {
        let s = Scene3D(camera: Camera3D(position: [0, 0, 3], target: .zero, fov: 30), background: .transparent,
                        effects: .cinematic, id: "test.transparent") {
            Sphere3D(radius: 0.3).material(.plastic(.red))
            Light3D.directional(from: [1, 2, 3])
        }
        let px = render(s, 200, 200)
        XCTAssertEqual(px.at(5, 5).a, 0, "corner should be fully transparent")
        XCTAssertEqual(px.at(100, 100).a, 255, "the sphere should be opaque")
        // Valid premultiplied pixels: no color above coverage (bloom/DOF fringes are clamped).
        var invalid = 0
        for i in stride(from: 0, to: px.bytes.count, by: 4) {
            let a = px.bytes[i + 3]
            if px.bytes[i] > a || px.bytes[i + 1] > a || px.bytes[i + 2] > a { invalid += 1 }
        }
        XCTAssertEqual(invalid, 0, "color above coverage would composite as a glowing fringe")
    }

    func testShadowCatcherDarkensBackdropView() {
        func shot(_ shadow: Bool) -> Pixels {
            render(Scene3D(camera: Camera3D(position: [0, 1.2, 1.2], target: .zero, fov: 40),
                           environment: .none, background: .view { Color(white: 0.6) },
                           effects: Effects3D(hdr: false), id: "test.catcher") {
                Box3D(size: 0.3).material(.matte(.white)).position(0, 0.4, 0)
                Floor3D(material: .shadowCatcher())
                Light3D.directional(from: [0, 5, 0.01], shadow: shadow ? .hard(extent: 1) : nil)
            }, 200, 200)
        }
        // The floor right under the box (the frame centre) is darker with shadows on.
        let lit = shot(false).at(100, 100), shaded = shot(true).at(100, 100)
        XCTAssertLessThan(shaded.r + 30, lit.r, "shadow catcher should darken the backdrop (\(shaded) vs \(lit))")
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sr3d-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func modelShot(_ model: Node3D, id: String) -> Pixels {
        render(Scene3D(camera: Camera3D(position: [0, 0.5, 4], target: [0, 0.5, 0], fov: 30),
                       environment: .studio, background: .color(.black), effects: Effects3D(hdr: false), id: id) {
            model
            Light3D.directional(from: [1, 2, 3])
        }, 200, 200)
    }

    func testOBJLoadingAndFit() throws {
        // A 20-unit cube from y = 0…20, written as a tiny OBJ.
        let v = [(-1.0, 0.0, -1.0), (1, 0, -1), (1, 2, -1), (-1, 2, -1), (-1, 0, 1), (1, 0, 1), (1, 2, 1), (-1, 2, 1)]
        var obj = "o Cube\n" + v.map { "v \($0.0 * 10) \($0.1 * 10) \($0.2 * 10)\n" }.joined()
        obj += ["1 4 3 2", "5 6 7 8", "1 2 6 5", "2 3 7 6", "3 4 8 7", "4 1 5 8"].map { "f \($0)\n" }.joined()
        let url = try tempDir().appendingPathComponent("cube.obj")
        try obj.write(to: url, atomically: true, encoding: .utf8)

        let loaded = try XCTUnwrap(Models3D.template(url.path))
        let b = try XCTUnwrap(loaded.bounds)
        XCTAssertEqual(Double(b.max.y - b.min.y), 20, accuracy: 0.01)
        // Fitted to 1 unit tall with its base on the floor: fills the frame centre (y 0…1).
        let px = modelShot(Model3D(url.path, fit: .height(1), anchor: .bottom).material(.matte(.white)), id: "test.obj")
        XCTAssertGreaterThan(px.at(100, 100).r, 30, "fitted cube should cover the centre")
        XCTAssertEqual(px.at(100, 5).r, 0, "and stay under y = 1")
        // Unfitted, the 20-unit cube swallows the camera's view entirely (we are inside it: back faces culled → black).
        XCTAssertFalse(modelShot(Model3D(url.path).material(.matte(.white)), id: "test.obj.raw").bytes == px.bytes)
    }

    func testModelPartsByName() throws {
        // A .scn with two named parts stacked: "Bottom" (y 0…0.5) and "Top" (y 0.5…1).
        let scene = SCNScene()
        for (name, y) in [("Bottom", 0.25), ("Top", 0.75)] {
            let n = SCNNode(geometry: SCNBox(width: 1, height: 0.5, length: 1, chamferRadius: 0))
            n.name = name
            n.position = SCNVector3(0, y, 0)
            scene.rootNode.addChildNode(n)
        }
        let url = try tempDir().appendingPathComponent("parts.scn")
        XCTAssertTrue(scene.write(to: url, options: nil, delegate: nil, progressHandler: nil))

        let model = Model3D(url.path).material(.matte(.white))
        let full = modelShot(model, id: "test.parts")
        let cut = modelShot(model.part("Top") { $0.hidden() }, id: "test.parts")
        let lifted = modelShot(model.part("Top") { $0.offset([0, 0.3, 0]) }, id: "test.parts")
        XCTAssertGreaterThan(full.at(100, 70).r, 30, "top part visible")
        XCTAssertLessThan(cut.at(100, 70).r, 5, "hidden part vanishes")
        XCTAssertGreaterThan(cut.at(100, 130).r, 30, "other parts stay")
        XCTAssertGreaterThan(lifted.at(100, 25).r, 30, "offset moves the part up from its rest pose")
        // Overrides never stick: the next frame without them is the untouched model again.
        XCTAssertTrue(modelShot(model, id: "test.parts").bytes == full.bytes)
    }

    /// The snippet in docs/ai-quickstart.md and docs/3d.md must keep compiling and rendering.
    func testDocSnippetRenders() {
        let t = 1.0, duration = 6.0
        let center: Vec3 = [0, 0.08, 0]
        let cam = Camera3D.dolly(t, from: .orbit(target: center, distance: 0.7, azimuth: -20, elevation: 14, fov: 24),
                                 to: .orbit(target: center, distance: 0.5, azimuth: 4, elevation: 10, fov: 24),
                                 start: 0, end: duration).focused(on: center, fStop: 2.8)
        let s = Scene3D(camera: cam, environment: .studio, background: .view { Color.gray }, effects: .cinematic,
                        id: "test.doc") {
            Slab3D(width: 0.0716, height: 0.1476, depth: 0.0078, cornerRadius: 0.0112,
                   screen: .screen(.view(width: 390, height: 844) { Color.blue }))
                .material(.metal(Color(white: 0.6), roughness: 0.34))
                .rotation(y: Motion3D.easedTurntable(t, degreesPerSecond: 12)).position(center)
            Model3D("models/robot.usdz", fit: .height(0.3), anchor: .bottom)
                .part("Head") { $0.rotated(Motion3D.oscillate(t, degrees: 15), axis: [0, 1, 0]) }
                .position(0.2, 0, 0)
            Text3D("Hello", size: 0.04, depth: 0.008).material(.plastic(.orange))
            Floor3D(material: .shadowCatcher())
            Light3D.directional(intensity: 900, from: [-0.1, 1, -0.2], at: center, shadow: .soft(extent: 0.25))
        }
        let px = render(s)
        let c = px.at(160, 90)
        XCTAssertGreaterThan(c.b, c.r, "the blue screen should sit in the middle of the frame")
    }

    func testMissingModelDrawsNothingButDoesNotCrash() {
        let px = render(Scene3D(camera: Camera3D(), background: .color(.black), id: "test.missing") {
            Model3D("does/not/exist.usdz")
        })
        XCTAssertEqual(px.at(160, 90).r, 0)
    }

    // MARK: camera & motion helpers

    func testOrbitCamera() {
        let c = Camera3D.orbit(target: [1, 0, 0], distance: 2, azimuth: 90, elevation: 0)
        XCTAssertEqual(c.position.x, 3, accuracy: 1e-9)
        XCTAssertEqual(c.position.z, 0, accuracy: 1e-9)
        let up = Camera3D.orbit(distance: 2, azimuth: 0, elevation: 90)
        XCTAssertEqual(up.position.y, 2, accuracy: 1e-9)
        XCTAssertEqual(simd_length(Camera3D.orbit(distance: 5, azimuth: 33, elevation: 21).position), 5, accuracy: 1e-9)
    }

    func testDollyLerpAndFocus() {
        let a = Camera3D(position: [0, 0, 4], target: .zero, fov: 40).focused(on: .zero, fStop: 2)
        XCTAssertEqual(a.depthOfField?.focusDistance ?? 0, 4, accuracy: 1e-9)
        let pushed = a.dollied(1)
        XCTAssertEqual(pushed.position.z, 3, accuracy: 1e-9)
        XCTAssertEqual(pushed.depthOfField?.focusDistance ?? 0, 3, accuracy: 1e-9, "focus follows a dolly")
        let b = Camera3D(position: [0, 2, 2], target: [0, 1, 0], fov: 20).focused(distance: 1, fStop: 4)
        let mid = Camera3D.lerp(a, b, 0.5)
        XCTAssertEqual(mid.position, [0, 1, 3])
        XCTAssertEqual(mid.fov, 30, accuracy: 1e-9)
        XCTAssertEqual(mid.depthOfField?.fStop ?? 0, 3, accuracy: 1e-9)
        XCTAssertEqual(Camera3D.dolly(0, from: a, to: b, start: 1, end: 2), a)
        XCTAssertEqual(Camera3D.dolly(5, from: a, to: b, start: 1, end: 2), b)
        let sprung = Camera3D.spring(30, from: a, to: b, start: 0)
        XCTAssertEqual(sprung.position.y, 2, accuracy: 1e-4)
    }

    func testMotionHelpers() {
        XCTAssertEqual(Motion3D.turntable(2, degreesPerSecond: 15, start: 10), 40)
        XCTAssertEqual(Motion3D.oscillate(0, degrees: 10), 0, accuracy: 1e-12)
        XCTAssertEqual(Motion3D.oscillate(1, degrees: 10, period: 4), 10, accuracy: 1e-9)
        // The eased turntable starts at rest and joins the constant spin without a jump.
        let r = 2.0, v = 30.0
        XCTAssertEqual(Motion3D.easedTurntable(0, degreesPerSecond: v, rampUp: r), 0)
        let before = Motion3D.easedTurntable(r - 1e-6, degreesPerSecond: v, rampUp: r)
        let after = Motion3D.easedTurntable(r + 1e-6, degreesPerSecond: v, rampUp: r)
        XCTAssertEqual(before, after, accuracy: 1e-3)
        XCTAssertEqual(Motion3D.easedTurntable(10, degreesPerSecond: v, rampUp: r), v * (10 - r / 2), accuracy: 1e-9)
    }

    func testLookAtPointsMinusZAtTarget() {
        let q = Rotation3D.lookAt(from: [0, 0, 0], to: [3, 0, 0])
        let forward = q.act([0, 0, -1])
        XCTAssertEqual(forward.x, 1, accuracy: 1e-9)
        let q2 = Rotation3D.lookAt(from: [0, 5, 0], to: .zero)   // straight down: up vector fallback
        XCTAssertEqual(q2.act([0, 0, -1]).y, -1, accuracy: 1e-9)
        // Euler y is a turntable spin about world up.
        let spin = Rotation3D.euler(x: 0, y: 90, z: 0).act([0, 0, 1])
        XCTAssertEqual(spin.x, 1, accuracy: 1e-9)
    }

    func testSlabMeshIsWellFormed() {
        let built = Geometries3D.make(.slab(width: 0.07, height: 0.14, depth: 0.008, cornerRadius: 0.01, edgeRadius: 0.0035))
        XCTAssertEqual(built.geometry.elementCount, 3, "front, back, sides")
        for src in built.geometry.sources where src.semantic == .normal || src.semantic == .vertex {
            src.data.withUnsafeBytes { raw in
                for i in 0..<(src.vectorCount * 3) {
                    XCTAssert(raw.load(fromByteOffset: i * 4, as: Float.self).isFinite)
                }
            }
        }
        let (lo, hi) = built.geometry.boundingBox
        XCTAssertEqual(Double(hi.x - lo.x), 0.07, accuracy: 1e-5)
        XCTAssertEqual(Double(hi.y - lo.y), 0.14, accuracy: 1e-5)
        XCTAssertEqual(Double(hi.z - lo.z), 0.008, accuracy: 1e-5)
    }
}
