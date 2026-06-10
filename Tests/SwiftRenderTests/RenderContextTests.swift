import SwiftUI
import XCTest
@testable import SwiftRender

final class RenderContextTests: XCTestCase {
    func testGeometryHelpers() {
        let portrait = RenderContext(size: CGSize(width: 1080, height: 1920), fps: 60)
        XCTAssertTrue(portrait.isVertical)
        XCTAssertFalse(portrait.isSquare)
        let square = RenderContext(size: CGSize(width: 1080, height: 1080), fps: 30)
        XCTAssertTrue(square.isSquare)
        let landscape = RenderContext(size: CGSize(width: 1920, height: 1080), fps: 60)
        XCTAssertEqual(landscape.referenceScale, 1.0)
        XCTAssertEqual(landscape.aspect, 1920.0 / 1080.0, accuracy: 1e-9)
    }

    /// A view that reads the environment renders differently per config —
    /// proves the Recorder actually injects the context.
    @MainActor func testRecorderInjectsContext() throws {
        struct Probe: View {
            @Environment(\.renderContext) var ctx
            var body: some View {
                (ctx.isVertical ? Color.white : Color.black)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        func render(_ size: CGSize, _ name: String) throws -> Data {
            let rec = Recorder(config: .init(fps: 12, size: size, postFX: false))
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try rec.renderPNG(at: 0, to: url) { _ in Probe() }
            return try Data(contentsOf: url)
        }
        let land = try render(CGSize(width: 64, height: 36), "ctx_l.png")
        let port = try render(CGSize(width: 36, height: 64), "ctx_p.png")
        XCTAssertNotEqual(land, port)
    }
}
