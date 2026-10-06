import XCTest
import SwiftRenderKit
@testable import SwiftRenderStudio

/// The whole hot-reload loop with real tools: FSEvents → `swift build --scratch-path
/// .build/studio` → blue/green host swap. The project is a tiny package whose
/// `swift-render serve` execs `swift-render-studio --fake-serve`, so every Studio
/// piece is real except the scene engine. Runs real compiles (~20 s), so opt-in:
///
///   SR_STUDIO_E2E=1 swift test --filter HotReloadE2ETests
@MainActor
final class HotReloadE2ETests: XCTestCase {
    func testEditBreakFixSwap() async throws {
        guard ProcessInfo.processInfo.environment["SR_STUDIO_E2E"] == "1" else {
            throw XCTSkip("set SR_STUDIO_E2E=1 to run real builds")
        }
        let studio = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("swift-render-studio")
        guard FileManager.default.isExecutableFile(atPath: studio.path) else { throw XCTSkip("studio binary not built") }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sr-e2e-\(UUID().uuidString.prefix(8))")
        let main = root.appendingPathComponent("Sources/Tiny/main.swift")
        try FileManager.default.createDirectory(at: main.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        // swift-tools-version: 5.10
        import PackageDescription
        let package = Package(name: "Tiny", platforms: [.macOS(.v14)],
                              targets: [.executableTarget(name: "swift-render", path: "Sources/Tiny")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        func source(_ decl: String) -> String {
            """
            import Foundation
            \(decl)
            guard CommandLine.arguments.dropFirst().first == "serve" else { print(generation); exit(0) }
            let argv: [UnsafeMutablePointer<CChar>?] = [strdup("\(studio.path)"), strdup("--fake-serve"), nil]
            execv("\(studio.path)", argv)
            perror("execv"); exit(1)
            """
        }
        try source("let generation = 1").write(to: main, atomically: true, encoding: .utf8)

        try await Task.sleep(for: .seconds(1))     // FSEvents may still report our own setup writes
        let model = ProjectModel(root: root)
        model.playback.displayWidth = 480
        await model.start()
        await waitUntil(240, "first build + host + frame") {
            if case .ready = model.host.state { return model.playback.hasFrame }
            return false
        }
        let g1 = model.build.generation
        XCTAssertEqual(g1, 1, "no rebuilds triggered by the build itself")
        XCTAssertEqual(model.selectedScene, FakeHostClient.scenes.first?.name)
        // The scratch path is canonical (/var/folders → /private/var/folders).
        XCTAssertEqual(model.build.scratchPath.path, BuildController.canonical(root).appendingPathComponent(".build/studio").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".build/studio/debug/swift-render").path))
        let firstPID = try XCTUnwrap(model.host.active?.pid)

        // Break it: the error arrives as a clickable diagnostic; the old host keeps serving.
        try source("let generation: Int = \"two\"").write(to: main, atomically: true, encoding: .utf8)
        await waitUntil(120, "failed build") { if case .failed = model.build.phase { return true }; return false }
        let err = try XCTUnwrap(model.build.errors.first)
        XCTAssertTrue(err.file.hasSuffix("Sources/Tiny/main.swift"), err.file)
        XCTAssertEqual(err.line, 2)
        XCTAssertEqual(model.host.active?.pid, firstPID)
        XCTAssertEqual(model.host.generation, g1)

        // Fix it: rebuild, swap to a new host process, new frame.
        let saved = Date()
        try source("let generation = 2").write(to: main, atomically: true, encoding: .utf8)
        await waitUntil(120, "swap to the next generation") { model.host.generation == g1 + 1 && model.host.active?.pid != firstPID }
        let swapped = Date().timeIntervalSince(saved)
        await waitUntil(10, "frame from the new host") { model.playback.hasFrame && model.playback.isRequestIdle }
        print(String(format: "[e2e] save → new host serving: %.2f s", swapped))
        await model.shutdown()
    }
}
