import CoreGraphics
import XCTest
import SwiftRenderKit
@testable import SwiftRenderStudio

/// Hot reload against the real engine and the real `swift-render serve` host, on this
/// repo: a throwaway solid-color scene is added under Sources/SwiftRender/Scenes, Studio
/// builds it into .build/studio, then each color edit is timed from the file write to
/// the first viewer frame showing the new color. The scene file is always deleted.
/// Edits the repo and runs real compiles, so opt-in:
///
///   SR_STUDIO_REAL_E2E=1 swift test --filter RealHostHotReloadTests
@MainActor
final class RealHostHotReloadTests: XCTestCase {
    static let scene = "ZZHotReloadProbe"

    func testColorEditReachesViewer() async throws {
        guard ProcessInfo.processInfo.environment["SR_STUDIO_REAL_E2E"] == "1" else {
            throw XCTSkip("set SR_STUDIO_REAL_E2E=1 to edit the repo and run real builds")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("Sources/SwiftRender/Scenes/\(Self.scene).swift")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "leftover probe scene")
        defer { try? FileManager.default.removeItem(at: file) }

        func write(_ rgb: (Double, Double, Double)) throws {
            try """
            import SwiftUI

            /// Temporary scene written by RealHostHotReloadTests; deleted when the test ends.
            public struct \(Self.scene): RenderScene {
                public static let defaultDuration: Double = 2
                public static var ownsPostFX: Bool { true }
                @MainActor public static func body(at t: Double, duration: Double) -> some View {
                    Color(red: \(rgb.0), green: \(rgb.1), blue: \(rgb.2))
                }
            }

            """.write(to: file, atomically: true, encoding: .utf8)
        }

        try write((1, 0, 0))
        try await Task.sleep(for: .seconds(1))     // let FSEvents pass our own setup write
        var options = LaunchOptions()
        options.scene = Self.scene
        options.at = 1
        let model = ProjectModel(root: root, options: options)
        model.playback.displayWidth = 480
        let t0 = Date()
        await model.start()
        await waitUntil(600, "first build + host + frame") {
            if case .ready = model.host.state { return model.playback.hasFrame }
            return false
        }
        XCTAssertEqual(model.info?.name, Self.scene)
        print(String(format: "[hot-reload] cold: build %.1f s, launch → first frame %.2f s",
                     model.build.lastSeconds ?? -1, Date().timeIntervalSince(t0)))
        XCTAssertEqual(dominant(model.playback.currentFrame), 0, "starts red")

        var samples: [Double] = []
        let colors: [((Double, Double, Double), Int)] = [((0, 0, 1), 2), ((0, 1, 0), 1), ((1, 0, 0), 0)]
        for (rgb, channel) in colors {
            let gen = model.build.generation
            let saved = Date()
            try write(rgb)
            await waitUntil(180, "frame with the new color") {
                model.build.generation > gen && dominant(model.playback.currentFrame) == channel
            }
            let s = Date().timeIntervalSince(saved)
            samples.append(s)
            print(String(format: "[hot-reload] edit → new pixels %.2f s (build %.2f s, host gen %d)",
                         s, model.build.lastSeconds ?? -1, model.host.generation))
        }
        let sorted = samples.sorted()
        print(String(format: "[hot-reload] median %.2f s over %d edits", sorted[sorted.count / 2], sorted.count))
        await model.shutdown()
    }
}

/// Index (0 r, 1 g, 2 b) of the strongest channel of the frame's average color.
private func dominant(_ f: DecodedFrame?) -> Int? {
    guard let img = f?.image else { return nil }
    var px = [UInt8](repeating: 0, count: 4)
    let ok = px.withUnsafeMutableBytes { buf -> Bool in
        guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return true
    }
    guard ok else { return nil }
    let rgb = px.prefix(3).map(Int.init)
    guard let m = rgb.max(), m > 96 else { return nil }
    return rgb.firstIndex(of: m)
}
