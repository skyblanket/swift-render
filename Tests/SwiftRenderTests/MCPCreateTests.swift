import AppKit
import XCTest
@testable import SwiftRenderKit

/// swift-render-mcp's creation tools (docs, launch_film, new_scene, init_project, get_props,
/// set_props) in standalone mode — a plain Swift package with no swift-render in it, the
/// `swift-render` CLI faked by a shell script via SWIFT_RENDER_CLI — and the docs resources.
final class MCPCreateTests: XCTestCase {
    private var serverBin: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("swift-render-mcp")
    }

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The fake `swift-render`: logs argv; `launch` writes the kept props + scan report and
    /// (unless --no-render) a film under the scanned folder; `new` / `init` scaffold like the
    /// real one; frames, sheets and renders copy a fixture PNG to `--out`.
    private static let fakeCLI = """
    #!/bin/sh
    echo "$*" >> "$FAKE_LOG"
    out=""; prev=""
    for a in "$@"; do [ "$prev" = "--out" ] && out="$a"; prev="$a"; done
    case "$1" in
      list)
        cat "$FAKE_LIST"; exit 0 ;;
      props)
        case "$2" in
          AppleLaunch) echo '{"name": "Notes", "tagline": "Write it down.", "features": [], "voiceover": false}'; exit 0 ;;
          Plain) echo "Plain takes no props" >&2; exit 1 ;;
        esac
        echo "Unknown scene: $2" >&2; exit 1 ;;
      launch)
        root="$2"; dir="$root/.swift-render/launch"; mkdir -p "$dir"
        case " $* " in *" --rescan "*) rm -f "$dir/Fake.json" ;; esac
        [ -f "$dir/Fake.json" ] || echo '{"name": "Fake", "tagline": "scanned", "features": []}' > "$dir/Fake.json"
        echo "{\\"root\\": \\"$root\\"}" > "$dir/Fake.scan.json"
        echo "[swift-render] launch: scanned $root (0.1s)"
        echo "  name        Fake   ← Package.swift"
        echo "  missing     git history (commits, contributors, tags)"
        echo "  props       .swift-render/launch/Fake.json"
        echo "  scan report .swift-render/launch/Fake.scan.json"
        case " $* " in *" --no-render "*) exit 0 ;; esac
        mkdir -p "$root/out"; : > "$root/out/fake-launch.mp4"
        echo "[swift-render] rendering AppleLaunch · 31.2s"
        echo "[swift-render] film → $root/out/fake-launch.mp4  (0.2s)"
        exit 0 ;;
      new)
        mkdir -p "$SWIFT_RENDER_ROOT/Sources/LaunchScenes"
        f="$SWIFT_RENDER_ROOT/Sources/LaunchScenes/$2.swift"; echo "// $2" > "$f"
        echo "[swift-render] created $f"; exit 0 ;;
      init)
        l="$2/Launch"; mkdir -p "$l/Sources/LaunchScenes"
        echo '{"product": "launch", "scenesDir": "Sources/LaunchScenes"}' > "$l/swift-render.json"
        echo "// scene" > "$l/Sources/LaunchScenes/FakeLaunch.swift"
        echo "[swift-render] init: $l"
        echo "  Package.swift"
        echo "  Sources/LaunchScenes/FakeLaunch.swift"
        echo ""
        echo "next:"
        echo "  cd Launch"
        exit 0 ;;
      frame|contact|check)
        cp "$FAKE_PNG" "$out"; exit 0 ;;
      render)
        : > "$out"; echo "[swift-render] done in 0.1s → $out"; exit 0 ;;
    esac
    exit 0

    """

    private struct Fake {
        var root: URL           // the workspace: a plain Swift package
        var cli: URL
        var log: URL
        var env: [String: String]
    }

    private func makeFake() throws -> Fake {
        guard FileManager.default.isExecutableFile(atPath: serverBin.path) else {
            throw XCTSkip("swift-render-mcp not built next to the test bundle (\(serverBin.path))")
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sr-create-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // The server reports real paths (/private/var/…, not /var/…): compare against those.
        let real = try XCTUnwrap(realpath(tmp.path, nil))
        let base = URL(fileURLWithPath: String(cString: real), isDirectory: true)
        free(real)
        let root = base.appendingPathComponent("Tally")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        try "// swift-tools-version: 5.10\nimport PackageDescription\nlet package = Package(name: \"Tally\")\n"
            .write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let tools = base.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let cli = tools.appendingPathComponent("swift-render")
        try Self.fakeCLI.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let list = base.appendingPathComponent("list.json")
        let scenes = [SceneSummary(name: "AppleLaunch", kind: .props, defaultDuration: 31.2, hasSoundtrack: true, hasProps: true),
                      SceneSummary(name: "Plain", kind: .render, defaultDuration: 4, hasSoundtrack: false, hasProps: false)]
        try JSONEncoder().encode(scenes).write(to: list)
        let png = base.appendingPathComponent("fixture.png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 18, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: png)
        let log = base.appendingPathComponent("cli.log")
        return Fake(root: root, cli: cli, log: log, env: [
            "SWIFT_RENDER_ROOT": "", "SWIFT_RENDER_CLI": cli.path,
            "FAKE_LOG": log.path, "FAKE_LIST": list.path, "FAKE_PNG": png.path,
        ])
    }

    private func start(_ fake: Fake, env extra: [String: String] = [:], cwd: URL? = nil) throws -> MCPTestClient {
        let c = try MCPTestClient(serverBin, env: fake.env.merging(extra) { $1 }, cwd: cwd ?? fake.root)
        addTeardownBlock { c.stop() }
        return c
    }

    private func calls(_ fake: Fake) -> [String] {
        ((try? String(contentsOf: fake.log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], url.path)
    }

    // MARK: protocol surface

    func testStandaloneServerDescribesItselfAndServesTheGuide() throws {
        let fake = try makeFake()
        let c = try start(fake)
        let info = try XCTUnwrap(c.initialize())
        XCTAssertNotNil((info["capabilities"] as? [String: Any])?["resources"], "resources capability declared")
        XCTAssertEqual((info["serverInfo"] as? [String: Any])?["title"] as? String, "swift-render (standalone)")
        let instructions = info["instructions"] as? String ?? ""
        XCTAssertTrue(instructions.contains("mode: standalone") && instructions.contains(fake.cli.path), instructions)
        for tool in ["docs", "launch_film", "new_scene", "init_project", "render_video", "check_scene"] {
            XCTAssertTrue(instructions.contains(tool), "recipe names \(tool)")
        }

        let tools = try XCTUnwrap(c.request("tools/list")?["result"] as? [String: Any])["tools"] as? [[String: Any]] ?? []
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.isSuperset(of: ["docs", "launch_film", "new_scene", "init_project", "get_props", "set_props"]
                                       + ReviewLoopTests.toolNames), "\(names)")
        for t in tools {
            let schema = t["inputSchema"] as? [String: Any] ?? [:]
            XCTAssertEqual(schema["type"] as? String, "object", "\(t["name"] ?? "?")")
            XCTAssertGreaterThan((t["description"] as? String ?? "").count, 40, "\(t["name"] ?? "?") is described")
            for (key, value) in schema["properties"] as? [String: Any] ?? [:] {
                let prop = value as? [String: Any] ?? [:]
                XCTAssertTrue(prop["type"] is String, "\(t["name"] ?? "?").\(key) has one JSON type (Codex/Gemini-safe)")
                XCTAssertNotNil(prop["description"], "\(t["name"] ?? "?").\(key) is described")
            }
        }

        // Resources: every topic, and the embedded quickstart is docs/ai-quickstart.md verbatim.
        let resources = try XCTUnwrap(c.request("resources/list")?["result"] as? [String: Any])["resources"] as? [[String: Any]] ?? []
        let uris = resources.compactMap { $0["uri"] as? String }
        XCTAssertTrue(uris.contains("swift-render://docs/scenes") && uris.contains("swift-render://docs/all"), "\(uris)")
        XCTAssertFalse(uris.contains("swift-render://docs/more"),
                       "every ## section of docs/ai-quickstart.md belongs to a topic (Guide.topics)")
        let all = c.request("resources/read", ["uri": "swift-render://docs/all"])
        let text = ((all?["result"] as? [String: Any])?["contents"] as? [[String: Any]])?.first?["text"] as? String
        let markdown = try String(contentsOf: Self.repoRoot.appendingPathComponent("docs/ai-quickstart.md"), encoding: .utf8)
        XCTAssertEqual(text, markdown.trimmingCharacters(in: .newlines),
                       "QuickstartText.swift is stale: run python3 scripts/embed-quickstart.py")
        let missing = c.request("resources/read", ["uri": "swift-render://docs/../../etc/passwd"])
        XCTAssertEqual((missing?["error"] as? [String: Any])?["code"] as? Int, -32002)

        let index = c.tool("docs")
        XCTAssertFalse(index.isError)
        XCTAssertTrue(index.text.contains("mode: standalone") && index.text.contains("`timeline`"), index.text)
        let scenes = c.tool("docs", ["topic": "scenes"])
        XCTAssertTrue(scenes.text.contains("## Mental model") && scenes.text.contains("## Common pitfalls"), scenes.text)
        XCTAssertTrue(c.tool("docs", ["topic": "sound"]).text.contains("No swish transitions"))
        XCTAssertTrue(c.tool("docs", ["topic": "nope"]).isError)

        let list = c.tool("list_scenes")
        XCTAssertFalse(list.isError, list.text)
        XCTAssertTrue(list.text.hasPrefix("mode: standalone") && list.text.contains("AppleLaunch · props"), list.text)
    }

    func testMakeSkillShipsInThePluginAndNamesRealTools() throws {
        let skill = try String(contentsOf: Self.repoRoot.appendingPathComponent(".claude/skills/swift-render-make/SKILL.md"),
                               encoding: .utf8)
        XCTAssertEqual(skill, try String(contentsOf: Self.repoRoot.appendingPathComponent("claude-plugin/skills/swift-render-make/SKILL.md"),
                                         encoding: .utf8), "plugin copy of the skill must match .claude/skills")
        XCTAssertTrue(skill.hasPrefix("---\nname: swift-render-make\ndescription: "))
        for tool in ["docs", "launch_film", "init_project", "new_scene", "contact_sheet", "render_frames", "check_scene",
                     "render_video", "get_props", "set_props"] {
            XCTAssertTrue(skill.contains("`\(tool) ") || skill.contains("`\(tool)`"), "skill teaches \(tool)")
        }
        let agents = try String(contentsOf: Self.repoRoot.appendingPathComponent("docs/agents.md"), encoding: .utf8)
        for client in ["claude mcp add", "claude_desktop_config.json", "[mcp_servers.swift-render]", ".cursor/mcp.json"] {
            XCTAssertTrue(agents.contains(client), "docs/agents.md covers \(client)")
        }
    }

    func testDocsOnlyWithoutACLI() throws {
        let fake = try makeFake()
        let c = try start(fake, env: ["SWIFT_RENDER_CLI": "/nonexistent/swift-render"])
        let info = try XCTUnwrap(c.initialize())
        XCTAssertTrue((info["instructions"] as? String ?? "").contains("mode: docs-only"))
        XCTAssertFalse(c.tool("docs", ["topic": "timeline"]).isError)
        let launch = c.tool("launch_film")
        XCTAssertTrue(launch.isError && launch.text.contains("SWIFT_RENDER_CLI"), launch.text)
    }

    /// Claude Desktop starts servers in `/`: no workspace unless SWIFT_RENDER_WORKSPACE names one.
    func testStartedInRootNeedsAPathOrTheWorkspaceVariable() throws {
        let fake = try makeFake()
        let bare = try start(fake, cwd: URL(fileURLWithPath: "/"))
        XCTAssertTrue((bare.initialize()?["instructions"] as? String ?? "").contains("no workspace"))
        let r = bare.tool("launch_film")
        XCTAssertTrue(r.isError && r.text.contains("pass path"), r.text)
        XCTAssertFalse(bare.tool("launch_film", ["path": fake.root.path, "preview": true]).isError)

        let named = try start(fake, env: ["SWIFT_RENDER_WORKSPACE": fake.root.path], cwd: URL(fileURLWithPath: "/"))
        XCTAssertTrue((named.initialize()?["instructions"] as? String ?? "").contains("workspace \(fake.root.path)"))
        XCTAssertFalse(named.tool("launch_film").isError)
        XCTAssertEqual(calls(fake).filter { $0 == "launch \(fake.root.path) --aspect 16:9" }.count, 1, "\(calls(fake))")
    }

    // MARK: launch_film

    func testLaunchFilmRendersEditsAndShowsTheFilm() throws {
        let fake = try makeFake()
        let c = try start(fake)
        let kept = fake.root.appendingPathComponent(".swift-render/launch/Fake.json")

        let r = c.tool("launch_film", ["preview": true])
        XCTAssertFalse(r.isError, r.text)
        XCTAssertEqual(r.images, 1, "a contact sheet comes back")
        XCTAssertTrue(r.text.contains("film: \(fake.root.path)/out/fake-launch.mp4"), r.text)
        XCTAssertTrue(r.text.contains("name        Fake") && r.text.contains("missing     git history"), r.text)
        XCTAssertTrue(r.text.contains("props file: \(kept.path)"), r.text)
        var log = calls(fake)
        XCTAssertTrue(log.contains("launch \(fake.root.path) --aspect 16:9 --preview"), "\(log)")
        XCTAssertTrue(log.contains { $0.hasPrefix("contact AppleLaunch --props \(kept.path) --aspect 16:9 --out \(fake.root.path)/.swift-render/cache/mcp/") }, "\(log)")

        // props merge into the kept file (the film) before the render; voiceover:false is written too.
        let edited = c.tool("launch_film", ["props": ["tagline": "Count anything."], "voiceover": false, "aspect": "9:16"])
        XCTAssertFalse(edited.isError, edited.text)
        let props = try json(kept)
        XCTAssertEqual(props["tagline"] as? String, "Count anything.")
        XCTAssertEqual(props["name"] as? String, "Fake", "other keys kept")
        XCTAssertEqual(props["voiceover"] as? Bool, false)
        log = calls(fake)
        XCTAssertTrue(log.contains("launch \(fake.root.path) --no-render"), "\(log)")
        XCTAssertTrue(log.contains("launch \(fake.root.path) --aspect 9:16"), "\(log)")

        // A wrong type is refused before anything is written or rendered.
        let before = try String(contentsOf: kept, encoding: .utf8)
        let bad = c.tool("launch_film", ["props": ["features": "fast"]])
        XCTAssertTrue(bad.isError && bad.text.contains("features: expected array"), bad.text)
        XCTAssertEqual(try String(contentsOf: kept, encoding: .utf8), before)

        // get_props / set_props see the same file; render tools use it for AppleLaunch.
        XCTAssertTrue(c.tool("get_props", ["scene": "AppleLaunch"]).text.contains("Count anything."))
        let set = c.tool("set_props", ["scene": "AppleLaunch", "props": ["tagline": "Saved.", "subtitle": NSNull()]])
        XCTAssertFalse(set.isError, set.text)
        XCTAssertEqual(try json(kept)["tagline"] as? String, "Saved.")
        XCTAssertFalse(c.tool("render_frames", ["scene": "AppleLaunch", "times": [2]]).isError)
        XCTAssertTrue(calls(fake).contains { $0.hasPrefix("frame AppleLaunch --at 2 ") && $0.contains("--props \(kept.path)") })
    }

    func testLaunchFilmPathIsConfined() throws {
        let fake = try makeFake()
        let c = try start(fake)
        for bad in ["/", "/etc", "/System/Library", "~", "no-such-dir"] {
            let r = c.tool("launch_film", ["path": bad])
            XCTAssertTrue(r.isError, "\(bad): \(r.text)")
        }
        let file = fake.root.appendingPathComponent("Package.swift").path
        XCTAssertTrue(c.tool("launch_film", ["path": file]).text.contains("existing directory"))
        XCTAssertFalse(calls(fake).contains { $0.hasPrefix("launch") }, "nothing was scanned")

        // A codebase outside the workspace: scanned without executing its manifest; writes stay in it.
        let other = fake.root.deletingLastPathComponent().appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let r = c.tool("launch_film", ["path": other.path])
        XCTAssertFalse(r.isError, r.text)
        XCTAssertTrue(r.text.contains("not executed"), r.text)
        XCTAssertTrue(calls(fake).contains("launch \(other.path) --no-manifest --aspect 16:9"), "\(calls(fake))")
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.appendingPathComponent(".swift-render/cache/mcp/launch-contact.png").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fake.root.appendingPathComponent(".swift-render/launch").path))
    }

    // MARK: props

    func testPropsAreValidatedAndConfined() throws {
        let fake = try makeFake()
        let c = try start(fake)
        let outside = fake.root.deletingLastPathComponent()

        for file in ["../../evil.json", "/tmp/evil-\(UUID().uuidString).json", "../Tally/Package.swift.json",
                     ".swift-render/launch/Fake.scan.json", "a/b"] {
            let r = c.tool("set_props", ["scene": "AppleLaunch", "props": ["tagline": "x"], "file": file])
            XCTAssertTrue(r.isError, "\(file): \(r.text)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("evil.json").path))
        XCTAssertTrue(c.tool("set_props", ["scene": "../Evil", "props": ["a": 1]]).text.contains("not a scene name"))
        XCTAssertTrue(c.tool("set_props", ["scene": "Plain", "props": ["a": 1]]).text.contains("takes no props"))
        XCTAssertTrue(c.tool("set_props", ["scene": "Nope", "props": ["a": 1]]).text.contains("unknown scene"))
        XCTAssertTrue(c.tool("set_props", ["scene": "AppleLaunch", "props": ["features": "x"]]).text.contains("expected array"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fake.root.appendingPathComponent(".swift-render/props").path),
                       "refusals write nothing")
        XCTAssertTrue(c.tool("get_props", ["scene": "AppleLaunch", "file": "../../../etc/hosts.json"]).isError)

        // No launch film here: set_props starts from the defaults and saves .swift-render/props/<Scene>.json.
        let saved = fake.root.appendingPathComponent(".swift-render/props/AppleLaunch.json")
        XCTAssertFalse(c.tool("set_props", ["scene": "AppleLaunch", "props": ["tagline": "Mine."]]).isError)
        XCTAssertEqual(try json(saved)["tagline"] as? String, "Mine.")
        XCTAssertEqual(try json(saved)["name"] as? String, "Notes", "merged over the defaults")
        // A named variant, rendered by name; inline props go to a scratch file, not the saved one.
        XCTAssertFalse(c.tool("set_props", ["scene": "AppleLaunch", "props": ["tagline": "EU"], "file": "eu-cut"]).isError)
        let variant = fake.root.appendingPathComponent(".swift-render/props/AppleLaunch/eu-cut.json")
        XCTAssertEqual(try json(variant)["tagline"] as? String, "EU")
        XCTAssertFalse(c.tool("contact_sheet", ["scene": "AppleLaunch", "props_file": "eu-cut"]).isError)
        XCTAssertTrue(calls(fake).contains { $0.hasPrefix("contact AppleLaunch") && $0.hasSuffix("--props \(variant.path)") })
        XCTAssertFalse(c.tool("render_video", ["scene": "AppleLaunch", "props": ["tagline": "Once"], "preview": true]).isError)
        let render = try XCTUnwrap(calls(fake).last { $0.hasPrefix("render AppleLaunch") })
        XCTAssertTrue(render.contains("--out \(fake.root.path)/out/AppleLaunch-preview.mp4 --preview --props "), render)
        XCTAssertEqual(try json(saved)["tagline"] as? String, "Mine.", "inline props are not saved")
        XCTAssertFalse(c.tool("render_frames", ["scene": "AppleLaunch", "times": [1], "props_file": "defaults"]).isError)
        XCTAssertFalse(try XCTUnwrap(calls(fake).last { $0.hasPrefix("frame") }).contains("--props"))
    }

    // MARK: new_scene / init_project

    func testNewSceneNeedsAProjectAndInitProjectMakesOne() throws {
        let fake = try makeFake()
        let c = try start(fake)
        let r = c.tool("new_scene", ["name": "Teaser"])
        XCTAssertTrue(r.isError && r.text.contains("init_project"), r.text)
        for bad in ["../../Evil", "lower", "Has Space", "A/B", String(repeating: "A", count: 101)] {
            XCTAssertTrue(c.tool("new_scene", ["name": bad]).text.contains("UpperCamelCase"), bad)
        }
        XCTAssertTrue(c.tool("new_scene", ["name": "Teaser", "kind": "video"]).isError)

        let made = c.tool("init_project")
        XCTAssertFalse(made.isError, made.text)
        let launch = fake.root.appendingPathComponent("Launch")
        XCTAssertTrue(made.text.contains("Sources/LaunchScenes/FakeLaunch.swift") && !made.text.contains("cd Launch"), made.text)
        XCTAssertTrue(made.text.contains("contact_sheet {scene:\"FakeLaunch\"}"), made.text)
        let initCall = try XCTUnwrap(calls(fake).first { $0.hasPrefix("init ") })
        XCTAssertTrue(initCall.hasPrefix("init \(fake.root.path)"), initCall)
        // Built inside a swift-render checkout: the Launch package depends on it by path.
        XCTAssertTrue(initCall.contains("--local \(Self.repoRoot.resolvingSymlinksInPath().path)")
                      || initCall.contains("--local \(Self.repoRoot.path)"), initCall)
        let again = c.tool("init_project")
        XCTAssertTrue(again.isError && again.text.contains("already has a Launch/ package"), again.text)
        XCTAssertEqual(calls(fake).filter { $0.hasPrefix("init ") }.count, 1)

        // The server adopted Launch/: new_scene lands there.
        let scene = c.tool("new_scene", ["name": "Teaser", "kind": "audio"])
        XCTAssertFalse(scene.isError, scene.text)
        XCTAssertTrue(scene.text.contains("Sources/LaunchScenes/Teaser.swift") && scene.text.contains("audio.band"), scene.text)
        XCTAssertTrue(calls(fake).contains("new Teaser --kind audio"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: launch.appendingPathComponent("Sources/LaunchScenes/Teaser.swift").path))
        let info = try XCTUnwrap(c.initialize())
        XCTAssertTrue((info["instructions"] as? String ?? "").contains("mode: project"), "initialize reports the new mode")
    }
}
