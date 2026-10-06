import XCTest
import SwiftRenderKit
@testable import SwiftRenderStudio

/// Launch options and per-scene state set up by ProjectModel itself.
@MainActor
final class ProjectModelTests: XCTestCase {
    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pm-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testSceneFromCommandLineLoadsItsSavedKnobs() async throws {
        let root = try tempRoot()
        let project = Project.open(root)
        try KnobFile.save(["logo.scale": .number(1.6), "headline": .string("SAVED OVERRIDE")],
                          to: project.knobsURL(scene: "LaunchFilm"))
        var o = LaunchOptions()
        o.fakeHost = true
        o.scene = "LaunchFilm"
        let model = ProjectModel(root: root, options: o)
        await model.start()
        await waitUntil(10, "scene open") { model.info != nil }
        XCTAssertEqual(model.knobValues["logo.scale"], .number(1.6))
        XCTAssertEqual(model.knobValues["headline"], .string("SAVED OVERRIDE"))
        XCTAssertFalse(model.inspector.isDirty, "nothing unsaved: the tab shows what the file says")
        XCTAssertEqual(model.host.info?.knobs.first { $0.key == "logo.scale" }?.value, .number(1.6),
                       "the host renders the same values the Knobs tab shows")
        await model.shutdown()
    }

    func testKnobAndPropsLaunchOptionsApplyWithoutTheInspectorOnScreen() async throws {
        let root = try tempRoot()
        try #"{"title":"FROM FILE","speed":0.5,"showGrid":false}"#.write(
            to: root.appendingPathComponent("p.json"), atomically: true, encoding: .utf8)
        var o = LaunchOptions()
        o.fakeHost = true
        o.scene = "JETRAYChase"
        o.knobs = ["logo.scale": "1.3"]
        o.propsFile = "p.json"
        let model = ProjectModel(root: root, options: o)
        // No InspectorView exists in this test: nothing but the model may run them.
        await model.start()
        await waitUntil(10, "launch options applied") {
            model.info != nil && !model.inspector.isBusy
        }
        XCTAssertEqual(model.knobValues["logo.scale"], .number(1.3))
        XCTAssertEqual(model.host.info?.knobs.first { $0.key == "logo.scale" }?.value, .number(1.3))
        XCTAssertTrue(model.propsJSON?.contains("FROM FILE") ?? false, model.propsJSON ?? "nil")
        await model.shutdown()
    }

    // MARK: New Launch Film in an `init` scaffold

    func testScaffoldLaunchFilmUsesTheAppNotTheLaunchPackage() throws {
        let app = try tempRoot()
        try "// app".write(to: app.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let launch = app.appendingPathComponent("Launch", isDirectory: true)
        try FileManager.default.createDirectory(at: launch.appendingPathComponent(".swift-render/launch"),
                                                withIntermediateDirectories: true)
        try #"{"product": "launch", "scenesDir": "Sources/LaunchScenes"}"#.write(
            to: launch.appendingPathComponent("swift-render.json"), atomically: true, encoding: .utf8)
        let saved = launch.appendingPathComponent(".swift-render/launch/TidepoolLaunch.json")
        try #"{"name": "Tidepool"}"#.write(to: saved, atomically: true, encoding: .utf8)
        let project = Project.open(launch)
        let scenes = [SceneSummary(name: "AppleLaunch", kind: .props, defaultDuration: 24, hasSoundtrack: true, hasProps: true),
                      SceneSummary(name: "TidepoolLaunch", kind: .props, defaultDuration: 24, hasSoundtrack: true, hasProps: true)]

        let t = ProjectModel.launchTarget(project: project, scenes: scenes)
        XCTAssertEqual(t.props?.lastPathComponent, "TidepoolLaunch.json", "init's scan of the app, not a rescan of Launch/")
        XCTAssertEqual(t.root.standardizedFileURL.path, app.standardizedFileURL.path)

        // Without init's props file: scan the app (parent), never the Launch package.
        try FileManager.default.removeItem(at: saved)
        let rescan = ProjectModel.launchTarget(project: project, scenes: scenes)
        XCTAssertNil(rescan.props)
        XCTAssertEqual(rescan.root.standardizedFileURL.path, app.standardizedFileURL.path)

        // An ordinary project scans itself.
        let plain = ProjectModel.launchTarget(project: Project.open(app), scenes: scenes)
        XCTAssertEqual(plain.root.standardizedFileURL.path, app.standardizedFileURL.path)
        XCTAssertNil(plain.props)
    }

    func testScannedArtPathsBecomeAbsoluteForAnotherPackagesHost() throws {
        var props = LaunchProps(name: "Tidepool")
        props.icon = LaunchProps.Icon(path: "Resources/AppIcon.png")
        props.screenshots = [LaunchProps.Screenshot(path: "docs/shot.png"), LaunchProps.Screenshot(path: "/abs/x.png")]
        let json = String(decoding: try JSONEncoder().encode(props), as: UTF8.self)
        let out = ProjectModel.absolutizingAssets(json, base: URL(fileURLWithPath: "/apps/Tidepool", isDirectory: true))
        let back = try JSONDecoder().decode(LaunchProps.self, from: Data(out.utf8))
        XCTAssertEqual(back.icon?.path, "/apps/Tidepool/Resources/AppIcon.png")
        XCTAssertEqual(back.screenshots.map(\.path), ["/apps/Tidepool/docs/shot.png", "/abs/x.png"])
        XCTAssertEqual(back.name, "Tidepool")
    }
}
