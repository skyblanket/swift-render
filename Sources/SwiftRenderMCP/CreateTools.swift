import Foundation
import SwiftRenderKit

// MARK: - Creation tools
//
// docs, launch_film, new_scene, init_project, get_props, set_props — and the `props`
// argument the render tools share. They work in every mode (see Workspace): `launch`,
// `init` and `new` run on the ready-built CLI when there is one, so a codebase that has
// never seen swift-render gets a film without building anything.
//
// Writes stay inside the folder a tool was pointed at (launch_film / init_project: the
// codebase; everything else: the project or workspace). Names and paths an agent passes
// are validated before they reach the file system.

extension ToolBox {
    var creationCatalog: [JSONObject] {
        func tool(_ name: String, _ title: String, _ description: String, _ props: JSONObject = [:],
                  required: [String] = [], readOnly: Bool = false, idempotent: Bool = false,
                  destructive: Bool = false, openWorld: Bool = false) -> JSONObject {
            Self.tool(name, title, description, props, required: required, readOnly: readOnly, idempotent: idempotent,
                      destructive: destructive, openWorld: openWorld)
        }
        let topics = Guide.topicIDs
        let path: JSONObject = ["type": "string",
                                "description": "The codebase folder (absolute, ~/…, or relative to the workspace): it must "
                                    + "hold a Package.swift, .xcodeproj, .xcworkspace or .git. Default: the workspace — "
                                    + "the Swift package / Xcode project the server runs in."]
        let anyFolder: JSONObject = ["type": "boolean",
                                     "description": "Accept a folder with none of those markers (default false). Hidden "
                                        + "folders, ~/Library and system folders are always refused."]
        let sceneName: JSONObject = ["type": "string", "pattern": "^[A-Z][A-Za-z0-9_]{0,99}$",
                                     "description": "UpperCamelCase Swift type name, e.g. \"ProductTeaser\" — not one "
                                        + "SwiftUI or swift-render already uses (Text, Score, Timeline…)."]
        return [
            tool("docs", "swift-render docs",
                 "The swift-render API guide, one topic at a time — read {topic:\"scenes\"} before writing a scene, so it "
                 + "compiles and looks right the first time. No topic: the index (how to make a video + every topic). "
                 + "Also served as resources swift-render://docs/<topic>.",
                 ["topic": ["type": "string", "enum": topics,
                            "description": "index (default), tools, scenes, timeline, easing, sound, knobs, launch, looks, "
                                + "cli, review, contributing (this repo only), or all (the whole quickstart)."] as JSONObject],
                 readOnly: true, idempotent: true),
            tool("launch_film", "Make a launch film",
                 "Scan a Swift codebase (Package.swift, Xcode project, asset catalog, README, CHANGELOG, git) and render an "
                 + "Apple-style launch film with the AppleLaunch scene. Returns the MP4 path, what it detected (name, "
                 + "tagline, features, version, platforms — each with its source file), the props file that defines the "
                 + "film, and a contact sheet so you can see it. Edit the film by passing props (merged into that file) "
                 + "and calling again. Writes only inside the codebase (.swift-render/launch/, out/). A full-quality film "
                 + "can take over a minute: past ~45 s the answer is a job id — poll render_status {job} for the result.",
                 ["path": path, "any_folder": anyFolder, "wait": Self.waitArg,
                  "aspect": Self.aspectArg,
                  "preview": ["type": "boolean",
                              "description": "Half resolution at 30 fps — several times faster; use it until the film "
                                + "looks right (default false)."] as JSONObject,
                  "voiceover": ["type": "boolean",
                                "description": "Narrate the film with on-device TTS (true) or remove the narration "
                                    + "(false). Default: as the props file says."] as JSONObject,
                  "props": ["type": "object", "additionalProperties": true,
                            "description": "Keys to change in the film's props before rendering, e.g. {\"tagline\": "
                                + "\"Count anything.\", \"features\": [{\"title\": \"Live\", \"detail\": \"…\", "
                                + "\"symbol\": \"bolt\"}]}; null removes a key. Every key: get_props {scene:\"AppleLaunch\"}."]
                    as JSONObject,
                  "rescan": ["type": "boolean",
                             "description": "Scan again and replace the props file (drops earlier edits). Default false: "
                                + "the kept props file wins."] as JSONObject,
                  "run_manifest": ["type": "boolean",
                                   "description": "Run `swift package dump-package` (executes Package.swift) for a "
                                    + "codebase outside the workspace. Default: only for the workspace itself."] as JSONObject,
                  "open": ["type": "boolean", "description": "Open the film in the default player when done (default false)."]
                    as JSONObject]),
            tool("new_scene", "New scene",
                 "Scaffold an auto-registered scene file (<Name>.swift with a Timeline, a Score and a fade) in the "
                 + "project's scenes folder and return its path, its source and a short guide to writing it. Needs a "
                 + "swift-render project — call init_project first in any other codebase. Then edit the file (or, without "
                 + "file tools, send the whole new source to write_scene) and call contact_sheet.",
                 ["name": sceneName,
                  "kind": ["type": "string", "enum": ["render", "audio"],
                           "description": "render (default) or audio — an AudioReactiveScene that gets band levels per frame."]
                    as JSONObject],
                 required: ["name"]),
            tool("write_scene", "Write scene source",
                 "Create or replace <Name>.swift in the project's scenes folder with `source`, then build and return the "
                 + "compiler diagnostics (file:line:col). For clients that can't edit files (Claude Desktop); with file "
                 + "tools, edit the file instead. The source must declare `public struct <Name>: RenderScene` (or "
                 + "AudioReactiveScene / PropsScene) — that registers it. Read a scene first with scene_info {scene, "
                 + "source:true}. Needs a swift-render project (init_project).",
                 ["name": sceneName,
                  "source": ["type": "string", "description": "The complete Swift file (import SwiftUI, import SwiftRender, …)."]
                    as JSONObject,
                  "wait": Self.waitArg],
                 required: ["name", "source"], idempotent: true, destructive: true),
            tool("init_project", "Set up a Launch package",
                 "Give a codebase its own swift-render package: <path>/Launch/ with the launch film as editable Swift "
                 + "(LaunchKit), a `launch` CLI, swift-render.json and .mcp.json. Refuses to overwrite files unless "
                 + "force. Afterwards this server works in that package: new_scene, list_scenes, render_* and review "
                 + "tools. It starts the first build at once as a job (it fetches swift-render and can take minutes): "
                 + "render_status {job} shows it.",
                 ["path": path, "any_folder": anyFolder,
                  "local": ["type": "string",
                            "description": "A swift-render checkout to depend on by path. Default: the checkout this server "
                                + "was built from, if any; else github.com/skyblanket/swift-render."] as JSONObject,
                  "remote": ["type": "boolean",
                             "description": "Depend on github.com/skyblanket/swift-render even when built from a checkout."]
                    as JSONObject,
                  "force": ["type": "boolean", "description": "Overwrite files already in <path>/Launch/ (default false)."]
                    as JSONObject,
                  "run_manifest": ["type": "boolean",
                                   "description": "As in launch_film: execute Package.swift outside the workspace."]
                    as JSONObject],
                 destructive: true, openWorld: true),
            tool("get_props", "Get scene props",
                 "The JSON a data-driven scene renders (AppleLaunch, any PropsScene): the props in use — saved with "
                 + "set_props, or for AppleLaunch the film launch_film made — else the scene's defaults with every key.",
                 ["scene": Self.sceneArg,
                  "file": ["type": "string",
                           "description": "Read this instead: a variant name, a .json path in the project, or "
                            + "\"defaults\"."] as JSONObject],
                 required: ["scene"], idempotent: true),
            tool("set_props", "Save scene props",
                 "Save props for a data-driven scene. Merges `props` into the current props (or the defaults; null "
                 + "removes a key) and writes .swift-render/props/<Scene>.json — or the launch film's props file for "
                 + "AppleLaunch after launch_film — which render_frames, contact_sheet, check_scene and render_video then "
                 + "use. Refuses unknown scenes, scenes without props and values of the wrong type; writes nothing then.",
                 ["scene": Self.sceneArg,
                  "props": ["type": "object", "additionalProperties": true,
                            "description": "Keys to set, e.g. {\"tagline\": \"Ship it.\"}."] as JSONObject,
                  "file": ["type": "string",
                           "description": "Save as a named variant instead (\"eu-cut\" → .swift-render/props/<Scene>/"
                            + "eu-cut.json, Studio's Props tab lists it) or to a .json path under .swift-render/props/ "
                            + "or .swift-render/launch/."] as JSONObject,
                  "replace": ["type": "boolean",
                              "description": "Write props exactly as given instead of merging (default false)."] as JSONObject],
                 required: ["scene", "props"], idempotent: true),
        ]
    }

    // MARK: docs

    func docs(_ a: Args) throws -> ToolResult {
        let topic = a.optionalString("topic") ?? "index"
        guard let text = Guide.text(topic) else {
            throw ToolError("unknown topic '\(topic.prefix(60))' — one of: \(Guide.topicIDs.joined(separator: ", "))")
        }
        var out = ToolResult()
        out.text(topic == "index" ? workspace.summary + "\n\n" + text : text)
        return out
    }

    // MARK: launch_film

    /// The codebase a launch/init call is about: `path`, else the workspace.
    private func codebase(_ a: Args) throws -> URL {
        let home = Workspace.homeDirectory(ProcessInfo.processInfo.environment)
        let any = a.bool("any_folder") ?? false
        if let raw = a.optionalString("path") {
            return try SafePath.codebase(raw, base: workspace.root ?? project?.root, home: home, anyFolder: any)
        }
        guard let root = workspace.root else {
            throw ToolError("no workspace (the server was started in \(FileManager.default.currentDirectoryPath)) — "
                            + "pass path: the codebase folder")
        }
        return try SafePath.codebase(root.path, base: nil, home: home, anyFolder: any)
    }

    /// Whether `swift package dump-package` may run for `root`: the workspace and the
    /// project are what the agent already works in; anything else needs run_manifest.
    private func manifestArgs(_ a: Args, root: URL, notes: inout [String]) -> [String] {
        let trusted = [workspace.root, project?.root].compactMap { $0 }.contains { SafePath.isInside(root, $0) }
        if trusted || (a.bool("run_manifest") ?? false) { return [] }
        notes.append("Package.swift was read as text, not executed (outside the workspace — run_manifest: true to allow)")
        return ["--no-manifest"]
    }

    func launchFilm(_ a: Args) throws -> ToolResult {
        let cli = try launcherCLI()
        let root = try codebase(a)
        let aspect = try Self.aspect(a) ?? "16:9"
        let preview = a.bool("preview") ?? false
        let voiceover = a.bool("voiceover")
        let rescan = a.bool("rescan") ?? false
        let open = a.bool("open") ?? false
        var notes: [String] = []
        let common = [root.path] + manifestArgs(a, root: root, notes: &notes)
        let edits: JSONObject?
        switch a.raw["props"] {
        case nil, is NSNull: edits = nil
        case let o as JSONObject: edits = o
        case let s as String:
            guard let o = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? JSONObject else {
                throw ToolError("props must be a JSON object of keys to change")
            }
            edits = o
        default: throw ToolError("props must be a JSON object of keys to change")
        }
        // launch writes .swift-render/launch/ and out/: neither may lead out of the codebase.
        try SafePath.confined(root.appendingPathComponent(".swift-render/launch"), root: root, sub: ".swift-render/launch")
        try SafePath.confined(root.appendingPathComponent("out"), root: root, sub: "out")
        // A wrong type is refused before anything is written, rendered or queued.
        if let edits {
            let mistyped = Self.mistyped(edits, against: try defaultProps("AppleLaunch", cli))
            guard mistyped.isEmpty else {
                throw ToolError("nothing was written or rendered — wrong value type:\n  " + mistyped.joined(separator: "\n  ")
                                + "\n(get_props {scene:\"AppleLaunch\"} shows every key)")
            }
        }

        let title = "launch_film \(root.lastPathComponent)" + " (\(aspect)\(preview ? ", preview" : ""))"
        let job = jobs.start(.launch, title, output: rescan ? nil : Self.plannedFilm(root: root, aspect: aspect)) { job in
            try self.runLaunchFilm(job, cli: BoundCLI(cli, cancel: job.token), root: root, common: common, aspect: aspect,
                                   preview: preview, voiceover: voiceover, rescan: rescan, open: open, edits: edits,
                                   notes: notes)
        }
        return waitFor(job, a)
    }

    /// The film `launch` will write when the codebase already has one kept props file:
    /// `out/<name>-launch[-9x16|-1x1].mp4` (launch's own naming).
    static func plannedFilm(root: URL, aspect: String) -> URL? {
        let kept = launchPropsFiles(in: root)
        guard kept.count == 1, let data = try? Data(contentsOf: kept[0]),
              let props = try? JSONDecoder().decode(LaunchProps.self, from: data) else { return nil }
        let name = props.validated().props.name
        let safe = String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" })
        let stem = safe.trimmingCharacters(in: CharacterSet(charactersIn: "-")).isEmpty ? "launch" : safe
        let suffix = aspect == "9:16" ? "-9x16" : aspect == "1:1" ? "-1x1" : ""
        return root.appendingPathComponent("out/\(stem.lowercased())-launch\(suffix).mp4")
    }

    /// The launch_film job: props edits into the kept file, the render (with progress), a contact sheet.
    private func runLaunchFilm(_ job: Job, cli: SceneCLI, root: URL, common: [String], aspect: String, preview: Bool,
                               voiceover: Bool?, rescan initialRescan: Bool, open: Bool, edits: JSONObject?,
                               notes initialNotes: [String]) throws -> ToolResult {
        var notes = initialNotes
        var rescan = initialRescan
        job.setPhase("scanning")
        // Edits go into the kept props file — the film — before the render reads it.
        if edits != nil || voiceover == false {
            let scan = try cli.runChecked(["launch"] + common + ["--no-render"] + (rescan ? ["--rescan"] : []), cwd: root)
            rescan = false
            let kept = try keptLaunchProps(stdout: scan.stdout, root: root)
            var obj = try readJSONObject(kept) ?? [:]
            let changed = Self.merge(edits ?? [:], into: &obj)
            if voiceover == false { obj["voiceover"] = false }
            let data = try Self.encode(obj)
            do { _ = try JSONDecoder().decode(LaunchProps.self, from: data) } catch {
                throw ToolError("those props don't fit AppleLaunch (nothing was written): \(Self.decodingProblem(error))"
                                + " — get_props {scene:\"AppleLaunch\"} shows every key")
            }
            try data.write(to: try SafePath.confined(kept, root: root, sub: ".swift-render/launch"), options: .atomic)
            if !changed.isEmpty { notes.append("props: set \(changed.joined(separator: ", ")) in \(SafePath.display(kept, from: root))") }
            if job.output == nil { job.output = Self.plannedFilm(root: root, aspect: aspect) }
        }

        var args = ["launch"] + common + ["--aspect", aspect]
        if preview { args.append("--preview") }
        if voiceover == true { args.append("--voiceover") }
        if rescan { args.append("--rescan") }
        if open { args.append("--open") }
        let started = Date()
        let r = try cli.runStreaming(args, cwd: root, job: job) { isErr, line in
            if !isErr, line.hasPrefix("[swift-render] rendering") {
                job.setPhase("rendering")
            } else if isErr, let m = line.range(of: #"\] (\d+)%$"#, options: .regularExpression),
                      let pct = Double(line[m].dropFirst(2).dropLast()) {
                job.setPhase("rendering")
                job.setProgress(done: pct, total: 100)
            }
        }
        let seconds = Date().timeIntervalSince(started)
        let kept = try keptLaunchProps(stdout: r.stdout, root: root)
        guard let film = Self.filmPath(r.stdout)?.canonical, FileManager.default.fileExists(atPath: film.path) else {
            throw ToolError("launch finished but reported no film:\n" + String(r.stdout.suffix(1500)))
        }
        job.output = film

        var lines = [String(format: "film: %@  (%@%@, rendered in %.0fs)", film.path, aspect, preview ? ", preview" : "", seconds)]
        lines += Self.scanSummary(r.stdout)
        lines.append("props file: \(kept.path) — this JSON is the film. Change it with launch_film {props:{…}} (merges, "
                     + "re-renders) or set_props {scene:\"AppleLaunch\", props:{…}}; every key: get_props {scene:\"AppleLaunch\"}.")
        let scanReport = kept.deletingPathExtension().appendingPathExtension("scan.json")
        if FileManager.default.fileExists(atPath: scanReport.path) {
            lines.append("scan report: \(scanReport.path) (each value with the file it came from)")
        }
        lines += notes
        lines.append("next: look at the contact sheet; fill gaps the scan listed as missing (never invent numbers); "
                     + (preview ? "render without preview when it looks right; " : "")
                     + "aspect \"9:16\" for the vertical cut; init_project to own the film as Swift.")
        var out = ToolResult()
        out.text(lines.joined(separator: "\n"))

        // The contact sheet: the same props, the same canvas.
        job.setPhase("contact sheet")
        do {
            let sheet = try scratch("launch-contact.png", in: root)
            try cli.runChecked(["contact", "AppleLaunch", "--props", kept.path, "--aspect", aspect, "--out", sheet.path],
                               cwd: root)
            out.text("contact sheet (15 frames across the film, each labelled with its time):")
            out.png(try ReviewImage.prepare(sheet, maxWidth: 1280))
        } catch {
            out.text("(contact sheet unavailable: \(error))")
        }
        return out
    }

    /// `<root>/.swift-render/launch/<Name>.json` — from launch's `props` line, else the newest scan.
    private func keptLaunchProps(stdout: String, root: URL) throws -> URL {
        let dir = root.appendingPathComponent(".swift-render/launch", isDirectory: true)
        for line in stdout.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("props ") else { continue }
            let rest = t.dropFirst("props".count).trimmingCharacters(in: .whitespaces)
            let rel = rest.components(separatedBy: "  (").first ?? rest
            let url = (rel.hasPrefix("/") ? URL(fileURLWithPath: rel) : root.appendingPathComponent(rel)).canonical
            if SafePath.isInside(url, dir), FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let files = Self.launchPropsFiles(in: root)
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
        guard let newest = dated.max(by: { $0.1 < $1.1 })?.0 else {
            throw ToolError("launch wrote no props under \(dir.path):\n" + String(stdout.suffix(1200)))
        }
        return newest
    }

    /// `.swift-render/launch/*.json` (not the scan reports) under `root`.
    static func launchPropsFiles(in root: URL?) -> [URL] {
        guard let root else { return [] }
        let dir = root.appendingPathComponent(".swift-render/launch", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".scan.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The film path from launch's `film → <path>  (12.3s)` line.
    static func filmPath(_ stdout: String) -> URL? {
        for line in stdout.split(separator: "\n") {
            guard let r = line.range(of: "film → ") else { continue }
            let rest = String(line[r.upperBound...])
            let path = rest.components(separatedBy: "  (").first ?? rest
            return URL(fileURLWithPath: path.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// launch's scan table (what it found, from where; gaps), without the progress lines.
    static func scanSummary(_ stdout: String) -> [String] {
        var lines: [String] = []
        var inTable = false
        for raw in stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("[swift-render] launch: scanned") {
                inTable = true
                lines.append("detected (" + line.replacingOccurrences(of: "[swift-render] launch: ", with: "") + "):")
                continue
            }
            guard inTable else { continue }
            let t = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[swift-render]") || t.hasPrefix("props ") || t.hasPrefix("scan report") { break }
            if !t.isEmpty { lines.append(line) }
        }
        return lines
    }

    // MARK: new_scene

    /// A name for a new scene type: UpperCamelCase, and not a type the scene's imports
    /// already declare (a scene called `Score` or `Text` breaks the whole package's build).
    static func newSceneName(_ a: Args) throws -> String {
        let name = try a.string("name")
        guard name.range(of: #"^[A-Z][A-Za-z0-9_]{0,99}$"#, options: .regularExpression) != nil else {
            throw ToolError("name must be an UpperCamelCase Swift type name (letters, digits, _; e.g. \"ProductTeaser\"), "
                            + "got '\(name.prefix(80))'")
        }
        if ReservedNames.all.contains(name) {
            throw ToolError("\(name) is already a type in SwiftUI, Foundation or swift-render — a scene with that name "
                            + "would shadow it and break the build. Pick another, e.g. \"\(name)Scene\" or \"My\(name)\".")
        }
        return name
    }

    func newScene(_ a: Args) throws -> ToolResult {
        let name = try Self.newSceneName(a)
        let kind = a.optionalString("kind") ?? "render"
        guard kind == "render" || kind == "audio" else { throw ToolError("kind must be render or audio (got \(kind))") }
        guard let project else {
            throw ToolError("new_scene needs a swift-render project to put the scene in (\(workspace.summary)). "
                            + "Call init_project first — it creates \(workspace.root.map { $0.path + "/Launch" } ?? "<path>/Launch"), "
                            + "a package for your own scenes — then new_scene again.")
        }
        let cli = try launcherCLI()
        // SWIFT_RENDER_ROOT pins `new` to this project (scenesDir from its swift-render.json).
        let r = try cli.runChecked(["new", name, "--kind", kind], cwd: project.root,
                                   environment: ["SWIFT_RENDER_ROOT": project.root.path])
        guard let created = Self.createdPath(r.stdout), SafePath.isInside(created, project.root) else {
            throw ToolError("`new \(name)` did not report a file inside \(project.root.path):\n\(r.stdout.suffix(800))")
        }
        var out = ToolResult()
        out.text("created \(SafePath.display(created, from: project.root)) (\(created.path)) — scene \"\(name)\", "
                 + "registered automatically at the next build (never edit main.swift).\n\n"
                 + Guide.newSceneNote(name: name, kind: kind))
        if let source = try? String(contentsOf: created, encoding: .utf8) {
            out.text("The scaffold (edit the file, or send a whole new version to write_scene {name, source}):\n\n" + source)
        }
        return out
    }

    // MARK: write_scene

    /// `public struct Name: …RenderScene…` — what SceneRegistryPlugin registers.
    static let sceneDecl = try! NSRegularExpression(pattern: #"public\s+struct\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([^{]+)\{"#)
    static let sceneProtocols: Set<String> = ["RenderScene", "AudioReactiveScene", "PropsScene", "PropsAudioScene"]

    func writeScene(_ a: Args) throws -> ToolResult {
        let name = try Self.newSceneName(a)
        guard let source = a.raw["source"] as? String, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError("missing required argument 'source' (the whole Swift file)")
        }
        guard source.utf8.count <= 300_000 else { throw ToolError("source is \(source.utf8.count / 1000) KB — split it up") }
        guard let project, let cli else {
            throw ToolError("write_scene needs a swift-render project to put the scene in (\(workspace.summary)). "
                            + "Call init_project first, then new_scene {name} or write_scene.")
        }
        let ns = source as NSString
        let declares = Self.sceneDecl.matches(in: source, range: NSRange(location: 0, length: ns.length)).contains { m in
            ns.substring(with: m.range(at: 1)) == name
                && ns.substring(with: m.range(at: 2)).split(whereSeparator: { ",: \n\t".contains($0) })
                    .contains { Self.sceneProtocols.contains(String($0)) }
        }
        guard declares else {
            throw ToolError("nothing was written — the source must declare `public struct \(name): RenderScene` (or "
                            + "AudioReactiveScene, PropsScene, PropsAudioScene); that is how scenes register. "
                            + "docs {topic:\"scenes\"} has a template.")
        }
        let sub = project.config.scenesDir ?? "Sources/SwiftRenderScenes"
        guard !sub.hasPrefix("/"), !sub.split(separator: "/").contains("..") else {
            throw ToolError("swift-render.json's scenesDir '\(sub)' must be a folder inside the project")
        }
        let dir = project.root.appendingPathComponent(sub, isDirectory: true)
        let file = dir.appendingPathComponent("\(name).swift")
        try SafePath.confined(file, root: project.root, sub: sub)
        // Another file declaring the type would fail the build with a confusing redeclaration.
        let others = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != file.lastPathComponent }
        if let clash = others.first(where: { url in
            (try? String(contentsOf: url, encoding: .utf8))?
                .range(of: #"(struct|class|enum)\s+\#(name)\b"#, options: .regularExpression) != nil
        }) {
            throw ToolError("nothing was written — \(SafePath.display(clash, from: project.root)) already declares \(name); "
                            + "edit that file's scene instead (scene_info {scene, source:true}) or pick another name")
        }
        let existed = FileManager.default.fileExists(atPath: file.path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = try SafePath.confined(file, root: project.root, sub: sub)
        try Data(source.utf8).write(to: target, options: .atomic)
        let head = "\(existed ? "replaced" : "created") \(SafePath.display(target, from: project.root)) "
            + "(\(source.split(separator: "\n", omittingEmptySubsequences: false).count) lines) — scene \"\(name)\""

        // Build now so the answer carries the compiler's verdict (the next scene tool would build anyway).
        let job = buildJob(cli, title: "build \(cli.product) (write_scene \(name))", fresh: true)
        var r = waitFor(job, a)
        var out = ToolResult()
        if job.isFinished, job.result != nil {
            out.text(head + (r.isError ? " — but the build failed; fix these and write_scene again:" : " — it builds."))
            out.content += r.content
            out.isError = r.isError
            if !r.isError { out.text("next: contact_sheet {scene:\"\(name)\"} to see it.") }
        } else {
            out.text(head + ".")
            out.content += r.content
        }
        r = out
        return r
    }

    static func createdPath(_ stdout: String) -> URL? {
        for line in stdout.split(separator: "\n") {
            guard let r = line.range(of: "created ") else { continue }
            return URL(fileURLWithPath: String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)).canonical
        }
        return nil
    }

    // MARK: init_project

    func initProject(_ a: Args) throws -> ToolResult {
        let cli = try launcherCLI()
        let root = try codebase(a)
        if Workspace.hostsScenes(root) {
            throw ToolError("\(root.path) is already a swift-render project — use new_scene there")
        }
        let force = a.bool("force") ?? false
        if !force, FileManager.default.fileExists(atPath: root.appendingPathComponent("Launch/swift-render.json").path) {
            throw ToolError("\(root.path) already has a Launch/ package — new_scene adds scenes to it "
                            + "(start the server in \(root.path) or Launch/); force: true regenerates it")
        }
        var notes: [String] = []
        var args = ["init", root.path] + manifestArgs(a, root: root, notes: &notes)
        if let local = a.optionalString("local") {
            let dir = try SafePath.codebase(local, base: workspace.root, home: Workspace.homeDirectory(ProcessInfo.processInfo.environment))
            args += ["--local", dir.path]
            notes.append("depends on swift-render at \(dir.path) (path dependency)")
        } else if !(a.bool("remote") ?? false), let checkout = workspace.checkout {
            args += ["--local", checkout.path]
            notes.append("depends on swift-render at \(checkout.path) — the checkout this server was built from "
                         + "(remote: true for the GitHub package)")
        } else {
            notes.append("depends on github.com/skyblanket/swift-render")
        }
        if force { args.append("--force") }
        try SafePath.confined(root.appendingPathComponent("Launch"), root: root, sub: "Launch")
        let r = try cli.runChecked(args, cwd: root)
        let launch = root.appendingPathComponent("Launch", isDirectory: true)
        guard FileManager.default.fileExists(atPath: launch.appendingPathComponent("swift-render.json").path) else {
            throw ToolError("init finished but \(launch.path)/swift-render.json is missing:\n\(r.stdout.suffix(1200))")
        }
        var lines = ["created \(launch.path):"]
        // init's file table, without its shell "next:" block (the tools below replace it).
        lines += r.stdout.components(separatedBy: "\n").prefix { $0.trimmingCharacters(in: .whitespaces) != "next:" }
            .filter { $0.hasPrefix("  ") && !$0.hasPrefix("    ") }
        lines += notes
        if project == nil {
            adopt(project: Project.open(launch))
            lines.append("This server now works in \(launch.path) (\(workspace.summary)).")
            // Start the first build now (it fetches swift-render): by the time the agent asks for
            // a frame it is done or under way, and no call has to sit through all of it.
            if let pcli = self.cli, FileManager.default.fileExists(atPath: launch.appendingPathComponent("Package.swift").path) {
                let job = buildJob(pcli, title: "build \(pcli.product) (first build of Launch/)")
                lines.append("Building the package now as job \(job.id) — the first build fetches swift-render and can "
                             + "take a few minutes. Scene tools wait for it; render_status {job:\"\(job.id)\"} shows it.")
            }
        } else {
            lines.append("This server stays on \(project!.root.path); start one in \(launch.path) to work there.")
        }
        let scene = Self.createdScene(in: launch)
        lines.append("next: " + (scene.map { "contact_sheet {scene:\"\($0)\"} shows the film as Swift; edit "
                                            + "Launch/Sources/LaunchScenes/\($0).swift; " } ?? "")
                     + "new_scene {name} adds your own scenes.")
        var out = ToolResult()
        out.text(lines.joined(separator: "\n"))
        return out
    }

    /// The `<App>Launch` scene init wrote.
    static func createdScene(in launch: URL) -> String? {
        let dir = launch.appendingPathComponent("Sources/LaunchScenes")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { $0.hasSuffix("Launch.swift") }.sorted().first.map { String($0.dropLast(".swift".count)) }
    }

    // MARK: props

    struct PropsChoice {
        var args: [String] = []
        var note: String? = nil
        /// The scratch file inline props were written to (the caller may remove it when done).
        var scratch: URL? = nil
    }

    /// `.swift-render/props/<Scene>.json` under home.
    func savedPropsURL(_ scene: String) throws -> URL {
        try home().appendingPathComponent(".swift-render/props", isDirectory: true)
            .appendingPathComponent(Project.fileComponent(scene: scene) + ".json")
    }

    /// The props a scene renders when no props argument is given: the saved file, else
    /// (AppleLaunch) the one film launch_film keeps in the workspace.
    func currentPropsURL(_ scene: String) throws -> URL? {
        let saved = try savedPropsURL(scene)
        if FileManager.default.fileExists(atPath: saved.path) { return saved }
        if scene == "AppleLaunch" {
            let kept = Self.launchPropsFiles(in: workspace.root ?? project?.root)
            if kept.count == 1 { return kept[0] }
        }
        return nil
    }

    /// A props reference an agent passed → a file. A bare name is a variant
    /// (`.swift-render/props/<Scene>/<name>.json`); anything else must be a `.json` path —
    /// inside the project/workspace to read, inside a `.swift-render/props` or
    /// `.swift-render/launch` folder there to write.
    func propsFile(_ scene: String, _ ref: String, forWriting: Bool) throws -> URL {
        let roots = try [home(), workspace.root, project?.root].compactMap { $0 }
        let url: URL
        if ref.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$"#, options: .regularExpression) != nil, !ref.hasSuffix(".json") {
            url = try home().appendingPathComponent(".swift-render/props", isDirectory: true)
                .appendingPathComponent(Project.fileComponent(scene: scene), isDirectory: true)
                .appendingPathComponent(ref + ".json")
        } else {
            guard ref.hasSuffix(".json"), !ref.contains("\0") else {
                throw ToolError("props file must be a variant name (letters, digits, . _ -) or a .json path, got '\(ref.prefix(120))'")
            }
            let expanded = (ref as NSString).expandingTildeInPath
            url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : try home().appendingPathComponent(expanded)
        }
        let resolved = url.canonical
        if forWriting {
            try Self.checkPropsWrite(resolved, roots: roots)
        } else {
            guard roots.contains(where: { SafePath.isInside(resolved, $0) }) else {
                throw ToolError("props file must be inside the project or workspace (not \(resolved.path))")
            }
            guard FileManager.default.fileExists(atPath: resolved.path) else {
                throw ToolError("no props file at \(resolved.path)" + (url.path == resolved.path ? "" : " (\(ref))"))
            }
        }
        return resolved
    }

    /// Props are written only under `<root>/.swift-render/props/` or `.swift-render/launch/`,
    /// with only `root` symlink-resolved: a symlinked `.swift-render`, `props` or variant
    /// folder resolves elsewhere and is refused.
    static func checkPropsWrite(_ url: URL, roots: [URL]) throws {
        let resolved = url.canonical
        let ok = roots.contains { root in
            [".swift-render/props", ".swift-render/launch"].contains { SafePath.isInside(resolved, root: root, sub: $0) }
        }
        guard ok, !resolved.lastPathComponent.hasSuffix(".scan.json") else {
            throw ToolError("props can only be saved under .swift-render/props/ or .swift-render/launch/ in the project "
                            + "(not \(resolved.path)\(resolved.path == url.path ? "" : ", where \(url.path) leads — a symlink?"))")
        }
    }

    /// The `props` / `props_file` arguments of the render tools → `--props <file>`.
    func propsChoice(_ a: Args, scene: String, auto: Bool, scratchTag: String? = nil) throws -> PropsChoice {
        if let raw = a.raw["props"], !(raw is NSNull) {
            guard let edits = (raw as? JSONObject)
                    ?? (raw as? String).flatMap({ try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? JSONObject }) else {
                throw ToolError("props must be a JSON object (use props_file for a saved variant or a path)")
            }
            let cli = try sceneCLI()
            let base = try currentPropsURL(scene)
            var obj = try base.flatMap(readJSONObject) ?? defaultProps(scene, cli)
            let changed = Self.merge(edits, into: &obj)
            var json = String(decoding: try Self.encode(obj), as: UTF8.self)
            // Relative art paths in a launch props file are relative to the scanned app.
            if let base, let root = PropsAssets.scannedRoot(forPropsFile: base) {
                json = PropsAssets.absolutizingPaths(in: json, root: root)
            }
            let url = try scratch("props-\(scene)\(scratchTag.map { "-" + $0 } ?? "").json")
            try json.write(to: url, atomically: true, encoding: .utf8)
            return PropsChoice(args: ["--props", url.path],
                               note: "props: \(base.map { SafePath.display($0, from: try? home()) } ?? "defaults") with "
                                + (changed.isEmpty ? "no changes" : changed.joined(separator: ", ")) + " (not saved — set_props saves)",
                               scratch: url)
        }
        if let ref = a.optionalString("props_file") {
            if ["defaults", "default", "none"].contains(ref) { return PropsChoice(note: "props: the scene's defaults") }
            let url = try propsFile(scene, ref, forWriting: false)
            return PropsChoice(args: ["--props", url.path], note: "props: \(SafePath.display(url, from: try home()))")
        }
        guard auto, let current = try currentPropsURL(scene) else { return PropsChoice() }
        return PropsChoice(args: ["--props", current.path],
                           note: "props: \(SafePath.display(current, from: try home())) (saved props — props_file:\"defaults\" ignores them)")
    }

    /// `props <Scene>` — the scene's default props. Unknown scenes and scenes without props
    /// are tool errors (callers write nothing then).
    func defaultProps(_ scene: String, _ cli: SceneCLI) throws -> JSONObject {
        let r = try cli.run(["props", scene])
        guard r.status == 0 else {
            let err = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if err.contains("Unknown scene") { throw ToolError("unknown scene '\(scene)' — see list_scenes; nothing was written") }
            if err.contains("takes no props") {
                throw ToolError("\(scene) takes no props (it is not a PropsScene) — tune it with set_knobs or edit its Swift")
            }
            throw ToolError("`\(cli.label) props \(scene)` failed (exit \(r.status)): \(err.suffix(600))")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? JSONObject else {
            throw ToolError("`\(cli.label) props \(scene)` printed no JSON object")
        }
        return obj
    }

    func getProps(_ a: Args) throws -> ToolResult {
        let scene = try a.scene()
        let cli = try sceneCLI()
        let defaults = try defaultProps(scene, cli)
        let base = try home()
        var out = ToolResult()
        let ref = a.optionalString("file")
        let current: URL? = ref == "defaults" ? nil : try ref.map { try propsFile(scene, $0, forWriting: false) } ?? currentPropsURL(scene)
        if let current {
            guard let obj = try readJSONObject(current) else { throw ToolError("\(current.path) is empty") }
            var text = "\(scene) props in \(SafePath.display(current, from: base))"
                + (ref == nil ? " — render tools use these unless you pass props/props_file:" : ":")
            text += "\n" + String(decoding: try Self.encode(obj), as: UTF8.self)
            let missing = defaults.keys.filter { obj[$0] == nil }.sorted()
            if !missing.isEmpty, scene != "AppleLaunch" {     // every LaunchProps key is optional
                text += "\nkeys in the defaults but not in this file (JSON decoding applies no Swift defaults): "
                    + missing.joined(separator: ", ")
            }
            out.text(text)
        } else {
            out.text("\(scene) default props (nothing saved"
                     + (scene == "AppleLaunch" ? "; launch_film keeps a film's props in <codebase>/.swift-render/launch/" : "")
                     + "):\n" + String(decoding: try Self.encode(defaults), as: UTF8.self))
        }
        var more: [String] = []
        let variants = (try? FileManager.default.contentsOfDirectory(
            at: base.appendingPathComponent(".swift-render/props/\(Project.fileComponent(scene: scene))"),
            includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent }
            .sorted() ?? []
        if !variants.isEmpty { more.append("variants (props_file / file): \(variants.joined(separator: ", "))") }
        if scene == "AppleLaunch" {
            let kept = Self.launchPropsFiles(in: workspace.root ?? project?.root)
            if kept.count > 1 { more.append("launch films here: " + kept.map { SafePath.display($0, from: base) }.joined(separator: ", ")) }
        }
        more.append("change: set_props {scene:\"\(scene)\", props:{key: value}} (merges; null removes a key)")
        out.text(more.joined(separator: "\n"))
        return out
    }

    func setProps(_ a: Args) throws -> ToolResult {
        let scene = try a.scene()
        let edits: JSONObject
        switch a.raw["props"] {
        case let o as JSONObject: edits = o
        case let s as String:
            guard let o = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? JSONObject else {
                throw ToolError("props must be a JSON object")
            }
            edits = o
        default: throw ToolError("missing required argument 'props' (a JSON object)")
        }
        let target = try a.optionalString("file").map { try propsFile(scene, $0, forWriting: true) }
            ?? currentPropsURL(scene) ?? savedPropsURL(scene)
        // Every target — the default one too — is checked, not just an agent-given path.
        try Self.checkPropsWrite(target, roots: [try home(), workspace.root, project?.root].compactMap { $0 })
        // Know the scene (and that it takes props) before touching the file system.
        let cli = try sceneCLI()
        let defaults = try defaultProps(scene, cli)
        let replace = a.bool("replace") ?? false
        var obj: JSONObject
        if replace {
            obj = [:]
        } else if FileManager.default.fileExists(atPath: target.path) {
            guard let existing = try? readJSONObject(target) else {
                throw ToolError("\(target.path) is not a JSON object — fix or remove it, or pass replace: true; nothing was written")
            }
            obj = existing
        } else {
            obj = defaults
        }
        let changed = Self.merge(edits, into: &obj)
        let data = try Self.encode(obj)
        var warnings: [String] = []
        let mistyped = Self.mistyped(edits, against: defaults)
        guard mistyped.isEmpty else {
            throw ToolError("nothing was written — wrong value type:\n  " + mistyped.joined(separator: "\n  "))
        }
        if scene == "AppleLaunch" {
            do { _ = try JSONDecoder().decode(LaunchProps.self, from: data) } catch {
                throw ToolError("those props don't fit AppleLaunch (nothing was written): \(Self.decodingProblem(error))")
            }
        } else {
            let unknown = edits.keys.filter { defaults[$0] == nil && !(edits[$0] is NSNull) }.sorted()
            if !unknown.isEmpty {
                warnings.append("warning: not in \(scene)'s default props (typo, or an optional key?): \(unknown.joined(separator: ", "))")
            }
            if replace {
                let missing = defaults.keys.filter { obj[$0] == nil }.sorted()
                if !missing.isEmpty {
                    warnings.append("warning: replace dropped keys the scene may require (JSON decoding applies no Swift "
                                    + "defaults): \(missing.joined(separator: ", "))")
                }
            }
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        let base = try home()
        var lines = ["saved \(scene) props → \(SafePath.display(target, from: base))"
                     + (changed.isEmpty ? "" : " (set \(changed.joined(separator: ", ")))")]
        lines += warnings
        let isDefault = (try? currentPropsURL(scene))?.path == target.path
        lines.append(isDefault
                     ? "render_frames, contact_sheet, check_scene and render_video use these now"
                        + (scene == "AppleLaunch" && target.path.contains("/.swift-render/launch/") ? "; so does launch_film" : "")
                     : "render with props_file: \"\(a.optionalString("file") ?? target.path)\"")
        var out = ToolResult()
        out.text(lines.joined(separator: "\n"))
        return out
    }

    // MARK: JSON helpers

    func readJSONObject(_ url: URL) throws -> JSONObject? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? JSONObject else {
            throw ToolError("\(url.path) is not a JSON object")
        }
        return obj
    }

    /// Shallow merge: each key replaces, `null` removes. Returns the keys touched.
    @discardableResult
    static func merge(_ edits: JSONObject, into obj: inout JSONObject) -> [String] {
        for (k, v) in edits {
            if v is NSNull { obj[k] = nil } else { obj[k] = v }
        }
        return edits.keys.sorted()
    }

    static func encode(_ obj: JSONObject) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    /// Edited keys whose JSON type differs from the scene's defaults ("features: expected
    /// array, got string") — the decoder would reject them or silently drop them.
    static func mistyped(_ edits: JSONObject, against defaults: JSONObject) -> [String] {
        edits.compactMap { k, v -> String? in
            guard !(v is NSNull), let d = defaults[k], !(d is NSNull), kind(d) != kind(v) else { return nil }
            return "\(k): expected \(kind(d)), got \(kind(v))"
        }.sorted()
    }

    static func kind(_ v: Any) -> String {
        switch v {
        case is NSNull: return "null"
        case let n as NSNumber: return CFGetTypeID(n) == CFBooleanGetTypeID() ? "boolean" : "number"
        case is String: return "string"
        case is [Any]: return "array"
        case is JSONObject: return "object"
        default: return "value"
        }
    }

    /// A DecodingError as one line an agent can act on.
    static func decodingProblem(_ error: Error) -> String {
        guard let e = error as? DecodingError else { return "\(error)" }
        func path(_ c: DecodingError.Context) -> String {
            let p = c.codingPath.map { $0.intValue.map { "[\($0)]" } ?? "." + $0.stringValue }.joined()
            return p.isEmpty ? "(top level)" : String(p.drop { $0 == "." })
        }
        switch e {
        case .typeMismatch(let type, let c): return "\(path(c)): expected \(type) — \(c.debugDescription)"
        case .valueNotFound(let type, let c): return "\(path(c)): missing \(type)"
        case .keyNotFound(let key, let c): return "\(path(c)): missing key \(key.stringValue)"
        case .dataCorrupted(let c): return "\(path(c)): \(c.debugDescription)"
        @unknown default: return "\(error)"
        }
    }
}
