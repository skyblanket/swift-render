import Foundation
import SwiftRenderKit

// MARK: - Tools
//
// Names and argument shapes are a contract with Studio, the swift-render-director
// agent (.claude/agents/swift-render-director.md) and every agent config in docs/agents.md.
// Review writes go through ReviewStore (flock) so Studio and the CLI can write
// concurrently; renders go through a CLI (see Workspace) so they use the code on disk.
// The creation tools (docs, launch_film, new_scene, init_project, get_props, set_props)
// live in CreateTools.swift.

final class ToolBox {
    /// Mode, workspace and CLIs. Changes once at most: `init_project` turns a standalone
    /// server into a project one.
    var workspace: Workspace { lock.lock(); defer { lock.unlock() }; return _workspace }
    private var _workspace: Workspace
    /// `initialize` reads the workspace on the reader thread while a call may adopt a project.
    private let lock = NSLock()
    private(set) var cli: ProjectCLI?
    /// Who agent replies are attributed to.
    let agentName: String
    /// The running call's cancel token, handed to every CLI it starts.
    private(set) var cancel: ProcessCancel?
    /// The running call's progress reporter (nil unless the client sent a progressToken).
    private(set) var progress: ProgressSink?
    /// Renders, launch films and builds (see Jobs.swift).
    let jobs = JobBoard()

    init(workspace: Workspace, agentName: String = "Claude") {
        self._workspace = workspace
        self.cli = workspace.project.map(ProjectCLI.init)
        self.agentName = agentName
    }

    /// Review-loop only (tests, Studio): a project and no standalone CLI.
    convenience init(project: Project?, agentName: String = "Claude") {
        self.init(workspace: Workspace(project: project, root: project?.root), agentName: agentName)
    }

    var project: Project? { workspace.project }

    /// After `init_project`: the new Launch/ package hosts scenes from now on.
    func adopt(project: Project) {
        lock.lock(); _workspace.project = project; lock.unlock()
        cli = ProjectCLI(project: project)
        cli?.cancel = cancel
    }

    private typealias Handler = (ToolBox) -> (Args) throws -> ToolResult

    private static let handlers: [String: Handler] = [
        "docs": ToolBox.docs,
        "launch_film": ToolBox.launchFilm,
        "new_scene": ToolBox.newScene,
        "init_project": ToolBox.initProject,
        "get_props": ToolBox.getProps,
        "set_props": ToolBox.setProps,
        "write_scene": ToolBox.writeScene,
        "list_scenes": ToolBox.listScenes,
        "scene_info": ToolBox.sceneInfo,
        "render_frames": ToolBox.renderFrames,
        "contact_sheet": ToolBox.contactSheet,
        "check_scene": ToolBox.checkScene,
        "build": ToolBox.build,
        "list_comments": ToolBox.listComments,
        "get_comment": ToolBox.getComment,
        "claim_comment": ToolBox.claimComment,
        "reply_comment": ToolBox.replyComment,
        "resolve_comment": ToolBox.resolveComment,
        "set_knobs": ToolBox.setKnobs,
        "render_video": ToolBox.renderVideo,
    ]

    func has(_ name: String) -> Bool { Self.handlers[name] != nil || name == "render_status" }

    /// Tools answered off the serial worker (main.swift): they only read the job board.
    static let concurrentTools: Set<String> = ["render_status"]

    /// Tools that run the project's CLI on the worker, so a project build comes first.
    private static let projectCLITools: Set<String> = [
        "list_scenes", "scene_info", "render_frames", "contact_sheet", "check_scene", "get_comment", "claim_comment",
        "reply_comment", "resolve_comment", "set_knobs", "get_props", "set_props",
    ]
    /// …of which these still answer when the build fails (the comment without its frame).
    private static let buildTolerantTools: Set<String> = ["get_comment", "claim_comment", "reply_comment"]

    /// Runs one tool. `cancel` stops any build/render child the call starts (MCP
    /// `notifications/cancelled`, server shutdown); `progress` reports while it waits on a job.
    func call(_ name: String, _ arguments: JSONObject, cancel: ProcessCancel? = nil,
              progress: ProgressSink? = nil) -> ToolResult {
        // Concurrent with the worker: touches no per-call state.
        if name == "render_status" { return renderStatus(Args(arguments), cancel: cancel, progress: progress) }
        guard let handler = Self.handlers[name] else { return .error("unknown tool \(name)") }
        self.cancel = cancel
        self.progress = progress
        cli?.cancel = cancel
        defer { cli?.cancel = nil; self.cancel = nil; self.progress = nil }
        let args = Args(arguments)
        let usesCLI = (Self.projectCLITools.contains(name) && (name != "reply_comment" || (args.bool("attach_frame") ?? false)))
            || (name == "new_scene" && workspace.cli == nil)
        if usesCLI, let waiting = buildFirst(before: name, strict: !Self.buildTolerantTools.contains(name)) {
            return waiting
        }
        do { return try handler(self)(Args(arguments)) }
        catch { return .error(String(describing: error)) }
    }

    // MARK: jobs

    /// How long a call waits for its job: `wait: true` until done, `wait: false` not at all,
    /// default `Jobs.detachAfter`.
    func budget(_ a: Args) -> TimeInterval {
        switch a.bool("wait") {
        case true?: return .infinity
        case false?: return 0
        case nil: return Jobs.detachAfter
        }
    }

    /// The tool's answer: the job's result when it finished in time, else its id and what to do.
    func waitFor(_ job: Job, _ a: Args, budget: TimeInterval? = nil) -> ToolResult {
        jobs.waitFor(job, budget: budget ?? self.budget(a), cancel: cancel, progress: progress) { job, waited in
            var out = ToolResult()
            let started = waited < 1 ? "started" : String(format: "still running after %.0fs", waited)
            out.text("""
            \(job.title): \(started) as job \(job.id) — it keeps going in the background.
            status: \(job.statusLine)
            next: render_status {job:"\(job.id)"} waits up to 30 s and reports progress; repeat until it says done — \
            then it returns this tool's result\(job.output.map { " (\($0.path))" } ?? ""). Don't start the same work again; \
            render_status {job:"\(job.id)", cancel:true} stops it.
            """)
            return out
        }
    }

    /// The running build job, or a new one. `fresh`: always a new one (queued after any
    /// running build), when sources changed after that build started.
    func buildJob(_ cli: ProjectCLI, title: String, fresh: Bool = false) -> Job {
        if !fresh, let running = jobs.unfinished(.build) { return running }
        return jobs.start(.build, title) { job in
            job.setPhase("building \(cli.product)")
            let r = try cli.build(cancel: job.token)
            var out = ToolResult()
            out.text(BuildReport.text(r, product: cli.product))
            out.isError = !r.success
            return out
        }
    }

    /// In a project whose sources changed, build first as a job: wait for it (leaving the tool
    /// time to run inside the client's limit), else answer with the job id. A failed build is
    /// the answer when `strict`. nil = go ahead.
    private func buildFirst(before tool: String, strict: Bool) -> ToolResult? {
        guard let cli else { return nil }
        let job: Job
        if let running = jobs.unfinished(.build) {
            job = running
        } else if cli.freshExecutable(cancel: cancel) == nil {
            job = buildJob(cli, title: "build \(cli.product) (sources changed)")
        } else {
            return nil
        }
        let budget = Jobs.detachAfter.isFinite ? max(5, Jobs.detachAfter - 15) : .infinity
        let r = jobs.waitFor(job, budget: budget, cancel: cancel, stopJobOnCancel: false, progress: progress) { job, waited in
            var out = ToolResult()
            out.text(String(format: """
            %@ needs %@ built first (sources changed); the build runs as job %@ and was still going after %.0fs.
            status: %@
            next: render_status {job:"%@"} until it says done, then call %@ again.
            """, tool, cli.product, job.id, waited, job.statusLine, job.id, tool))
            return out
        }
        if !job.isFinished || (strict && r.isError) { return r }
        return nil
    }

    /// `render_status {job?, wait?, cancel?}` — never queued behind the worker.
    func renderStatus(_ a: Args, cancel: ProcessCancel?, progress: ProgressSink?) -> ToolResult {
        var out = ToolResult()
        guard let id = a.optionalString("job") else {
            let all = jobs.all
            out.text(all.isEmpty ? "No jobs yet. render_video, launch_film, build and write_scene start one when they "
                                    + "take longer than \(Int(Jobs.detachAfter.isFinite ? Jobs.detachAfter : 45)) s."
                     : all.reversed().map(\.statusLine).joined(separator: "\n"))
            return out
        }
        guard let job = jobs.job(id) else {
            return .error("no job '\(id.prefix(40))' — this server's jobs: "
                          + (jobs.all.map(\.id).joined(separator: ", ").nilIfEmpty ?? "none")
                          + " (job ids don't survive a server restart)")
        }
        if a.bool("cancel") ?? false {
            if !job.isFinished { job.cancel(); _ = job.wait(5) }
            out.text(job.statusLine)
            return out
        }
        let wait = min(Jobs.statusWaitCap, max(0, a.double("wait") ?? 30))
        if !job.isFinished {
            _ = jobs.waitFor(job, budget: wait, cancel: cancel, stopJobOnCancel: false, progress: progress) { _, _ in ToolResult() }
        }
        guard job.isFinished, let result = job.result else {
            out.text(job.statusLine + "\nnext: render_status {job:\"\(job.id)\"} again.")
            return out
        }
        out.text(job.statusLine)
        out.content += result.content
        out.isError = result.isError
        return out
    }

    // MARK: catalog

    /// One tool's catalog entry. Annotations: `readOnly` — changes nothing on disk (no
    /// cache, no build); `idempotent` — repeating the call with the same arguments has no
    /// further effect; `destructive` — may overwrite what someone wrote; `openWorld` — talks
    /// to the network.
    static func tool(_ name: String, _ title: String, _ description: String, _ props: JSONObject = [:],
                     required: [String] = [], readOnly: Bool = false, idempotent: Bool = false,
                     destructive: Bool = false, openWorld: Bool = false) -> JSONObject {
        var schema: JSONObject = ["type": "object", "properties": props, "additionalProperties": false]
        if !required.isEmpty { schema["required"] = required }
        var hints: JSONObject = ["readOnlyHint": readOnly, "openWorldHint": openWorld]
        if !readOnly { hints["idempotentHint"] = idempotent; hints["destructiveHint"] = destructive }
        return ["name": name, "title": title, "description": description, "inputSchema": schema, "annotations": hints]
    }

    static let waitArg: JSONObject = [
        "type": "boolean",
        "description": "Default (omitted): wait up to 45 s, then answer with a job id and keep working in the background "
            + "(poll render_status) — safe in clients that stop tool calls after ~60 s (Claude Desktop). "
            + "true: wait until done (clients without that limit). false: answer with the job id at once.",
    ]

    static let sceneArg: JSONObject = ["type": "string",
                                       "description": "Scene name (a Swift type name), e.g. \"AppleLaunch\" — see list_scenes."]
    static let aspectArg: JSONObject = ["type": "string", "enum": ["16:9", "9:16", "1:1"],
                                        "description": "Canvas aspect: 16:9 landscape (default), 9:16 vertical, 1:1 square."]
    static let propsArg: JSONObject = [
        "type": "object", "additionalProperties": true,
        "description": "Props for a data-driven scene (AppleLaunch or any PropsScene), e.g. {\"tagline\": \"Ship it.\"}: "
            + "missing keys keep their current values. Omit both props and props_file to use the props saved with "
            + "set_props (for AppleLaunch, else the film launch_film made here), else the scene's defaults.",
    ]
    static let propsFileArg: JSONObject = [
        "type": "string",
        "description": "Instead of props: a variant name saved with set_props {file}, a .json path inside the project, "
            + "or \"defaults\" (ignore saved props).",
    ]

    var catalog: [JSONObject] {
        func tool(_ name: String, _ title: String, _ description: String, _ props: JSONObject = [:],
                  required: [String] = [], readOnly: Bool = false, idempotent: Bool = false) -> JSONObject {
            Self.tool(name, title, description, props, required: required, readOnly: readOnly, idempotent: idempotent)
        }
        let scene = Self.sceneArg
        let id: JSONObject = ["type": "string", "description": "Comment id, e.g. \"c1a2b3c4d\" (a unique prefix works)."]
        let onComment: JSONObject = ["type": "string",
                                     "description": "Optional comment id: render on that comment's canvas (aspect, size, "
                                        + "pinned duration) — the same composition get_comment and resolve_comment show."]
        let aspect: JSONObject = ["type": "string", "enum": ["16:9", "9:16", "1:1"],
                                  "description": "Optional canvas aspect (default: the scene's own). Ignored with `comment`."]
        let props = Self.propsArg
        return creationCatalog + [
            tool("render_status", "Job status",
                 "Progress and result of a job — what render_video, launch_film, build, write_scene or a rebuild hand back "
                 + "when they take longer than ~45 s (\"started as job j3\"). Waits up to `wait` seconds (default 30) for it "
                 + "to finish; once done it returns that tool's result (film path, contact sheet, build diagnostics). "
                 + "No job: lists every job. cancel: true stops it.",
                 ["job": ["type": "string", "description": "Job id, e.g. \"j3\"."] as JSONObject,
                  "wait": ["type": "number", "minimum": 0, "maximum": 50,
                           "description": "Seconds to wait for it to finish before answering (default 30, max 50)."] as JSONObject,
                  "cancel": ["type": "boolean", "description": "Stop the job (default false)."] as JSONObject],
                 readOnly: true),
            tool("list_scenes", "List scenes",
                 "Scenes this server can render (first line says the mode: project or standalone): kind, default length, "
                 + "score/props, and in a project how many open review comments each has. Standalone lists the templates "
                 + "(data-driven scenes such as AppleLaunch) unless all: true.",
                 ["all": ["type": "boolean",
                          "description": "Standalone mode: also list the built-in demo films (examples, not templates)."]
                    as JSONObject],
                 idempotent: true),
            tool("scene_info", "Scene structure",
                 "Clips (start/end, transition, source file:line), knobs, captions and score events for one scene. "
                 + "Use it to map a timecode to the code that draws it. source: true appends the scene's Swift file.",
                 ["scene": scene,
                  "source": ["type": "boolean",
                             "description": "Also return the scene's source file (for clients without file tools, "
                                + "e.g. Claude Desktop: edit it, then write_scene)."] as JSONObject],
                 required: ["scene"], idempotent: true),
            tool("render_frames", "Render frames",
                 "Render the scene at one or more times from the code on disk (rebuilds first if sources changed) "
                 + "and return the frames as PNG images. Look at these after every edit.",
                 ["scene": scene,
                  "times": ["type": "array", "items": ["type": "number"], "minItems": 1, "maxItems": 8,
                            "description": "Seconds from scene start."] as JSONObject,
                  "width": ["type": "integer", "minimum": 160, "maximum": 1280,
                            "description": "Returned image width in px (default 960, max 1280)."] as JSONObject,
                  "comment": onComment, "aspect": aspect, "props": props, "props_file": Self.propsFileArg],
                 required: ["scene", "times"], idempotent: true),
            tool("contact_sheet", "Contact sheet",
                 "A grid of thumbnails across the whole scene (each labelled with its time) — the fastest way to see "
                 + "its overall shape. Look at one after every change.",
                 ["scene": scene, "comment": onComment, "aspect": aspect, "props": props, "props_file": Self.propsFileArg],
                 required: ["scene"], idempotent: true),
            tool("check_scene", "Check scene",
                 "Run `check`: contact sheet + blank-frame scan + audio report (loudness, clipping, house-rule warnings "
                 + "such as whoosh/riser sweeps). Run before finishing.",
                 ["scene": scene, "comment": onComment, "aspect": aspect, "props": props, "props_file": Self.propsFileArg],
                 required: ["scene"], idempotent: true),
            tool("build", "Build",
                 "Build the project's CLI product now and return compiler diagnostics (file:line:col). "
                 + "Other tools also rebuild automatically when sources changed. A long build (the first one fetches "
                 + "swift-render) continues as a job: see wait and render_status.",
                 ["wait": Self.waitArg], idempotent: true),
            tool("list_comments", "List review comments",
                 "Review comments, newest state from .swift-render/reviews. Default: active (open + inProgress).",
                 ["scene": scene,
                  "status": ["type": "string",
                             "description": "Comma list of open, inProgress, resolved, wontFix — or \"active\" (default) or \"all\"."]
                    as JSONObject],
                 readOnly: true),
            tool("get_comment", "Get review comment",
                 "One comment with its thread, the frame at its time with the region boxed in pink, "
                 + "and the clips active at that time with their source file:line.",
                 ["id": id], required: ["id"], idempotent: true),
            tool("claim_comment", "Claim review comment",
                 "Mark a comment inProgress, assigned to you, and capture a before-frame (if it has none). "
                 + "Claim right before you start editing for it.",
                 ["id": id], required: ["id"]),
            tool("reply_comment", "Reply to review comment",
                 "Add a reply to a comment's thread (e.g. a clarifying question; the status is unchanged unless "
                 + "reopen). attach_frame renders the current frame at the comment's time and attaches it.",
                 ["id": id, "body": ["type": "string", "description": "Reply text."] as JSONObject,
                  "attach_frame": ["type": "boolean", "description": "Attach the current frame (default false)."] as JSONObject,
                  "reopen": ["type": "boolean",
                             "description": "Give a claimed comment back: inProgress → open (default false)."] as JSONObject],
                 required: ["id", "body"]),
            tool("resolve_comment", "Resolve review comment",
                 "Render the after-frame at the comment's time, attach it on a reply carrying your summary, and mark "
                 + "the comment resolved. Fails (and changes nothing) if the project doesn't build or render.",
                 ["id": id, "summary": ["type": "string",
                                        "description": "What you changed and where (file:line), in a sentence or two."]
                    as JSONObject],
                 required: ["id", "summary"]),
            tool("set_knobs", "Set knob overrides",
                 "Write knob overrides to .swift-render/knobs/<Scene>.json (merged; null removes a key). "
                 + "Knobs are Knob.double/bool/text/color values in the scene — no rebuild needed.",
                 ["scene": scene,
                  "values": ["type": "object", "description": "key → number | boolean | string (\"#RRGGBB\" for colors) | null",
                             "additionalProperties": true] as JSONObject,
                  "reset": ["type": "boolean", "description": "Clear all overrides first."] as JSONObject],
                 required: ["scene", "values"], idempotent: true),
            tool("render_video", "Render video",
                 "Render the scene to an MP4 and return its path (out/<Scene>[-9x16|-1x1][-preview].mp4 in the project, "
                 + "or the workspace in standalone mode). preview=true is half resolution at 30 fps — much faster; do the "
                 + "full render last. A render longer than ~45 s continues as a job: the answer names it and the MP4 "
                 + "path; poll render_status {job} until done.",
                 ["scene": scene,
                  "preview": ["type": "boolean", "description": "Fast preview render (default false)."] as JSONObject,
                  "aspect": Self.aspectArg, "props": props, "props_file": Self.propsFileArg, "wait": Self.waitArg],
                 required: ["scene"], idempotent: true),
        ]
    }

    // MARK: helpers

    /// The project's own CLI — review comments, builds and knobs need one.
    func requireProject() throws -> (Project, ProjectCLI) {
        guard let project, let cli else {
            throw ToolError("this needs a swift-render project (\(workspace.summary)). Start the server in one, set "
                            + "SWIFT_RENDER_ROOT, or call init_project to give this codebase its own Launch/ package")
        }
        return (project, cli)
    }

    /// The CLI scene tools run: the project's (rebuilt when sources change), else the
    /// standalone `swift-render` with the workspace (or a temp folder) as its cwd.
    func sceneCLI() throws -> SceneCLI {
        if let cli { cli.cancel = cancel; return cli }
        guard let url = workspace.cli else { throw ToolError(workspace.summary) }
        let s = StandaloneCLI(url: url, cwd: try home())
        s.cancel = cancel
        return s
    }

    /// The CLI for `launch`, `init` and `new`: the ready-built one when there is one (no build
    /// needed — every SwiftRenderTool CLI has these), else the project's.
    func launcherCLI() throws -> SceneCLI {
        if let url = workspace.cli {
            let s = StandaloneCLI(url: url, cwd: try home())
            s.cancel = cancel
            return s
        }
        if let cli { cli.cancel = cancel; return cli }
        throw ToolError(workspace.summary)
    }

    /// Where renders, saved props and scratch go: the project, else the workspace, else
    /// a folder in the temp directory (Claude Desktop starts servers in `/`).
    func home() throws -> URL {
        if let root = project?.root ?? workspace.root { return root }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("swift-render-mcp", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func requireStore() throws -> ReviewStore {
        ReviewStore(project: try requireProject().0)
    }

    /// `<home>/.swift-render/cache/mcp/<name>` (removed first).
    func scratch(_ name: String, in base: URL? = nil) throws -> URL {
        if base == nil, let project { try project.ensureDotDir() }
        let dir = try Self.cacheDir(in: base ?? home())
        let url = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        return url
    }

    /// `<root>/.swift-render/cache/mcp`, with the `.swift-render/.gitignore` that keeps it out of git.
    static func cacheDir(in root: URL) throws -> URL {
        let fm = FileManager.default
        let dot = root.appendingPathComponent(".swift-render", isDirectory: true)
        let dir = dot.appendingPathComponent("cache/mcp", isDirectory: true)
        // A symlinked .swift-render or cache/ must not carry scratch files out of the folder.
        try SafePath.confined(dir, root: root, sub: ".swift-render/cache/mcp")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try SafePath.confined(dir, root: root, sub: ".swift-render/cache/mcp")
        let ignore = dot.appendingPathComponent(".gitignore")
        if !fm.fileExists(atPath: ignore.path) {
            try "cache/\nreviews/.*.lock\n".write(to: ignore, atomically: true, encoding: .utf8)
        }
        return dir
    }

    /// CLI options that put a render on a comment's canvas (size + fps, else its aspect,
    /// plus a pinned duration), or on `aspect`; empty = the scene's own canvas.
    private func canvasArgs(comment: ReviewComment?, aspect: String? = nil) -> [String] {
        var args: [String] = []
        if let canvas = comment?.canvas {
            args += ["--width", "\(canvas.width)", "--height", "\(canvas.height)", "--fps", "\(canvas.fps)"]
        } else if let aspect = comment?.context?["aspect"] ?? aspect {
            args += ["--aspect", aspect]
        }
        if let pinned = comment?.context?["duration"] { args += ["--duration", pinned] }
        return args
    }

    /// Width in px of the canvas a render will use (for scaling previews).
    private func canvasWidth(comment: ReviewComment?, aspect: String?) -> Double {
        if let w = comment?.canvas?.width { return Double(w) }
        switch comment?.context?["aspect"] ?? aspect {
        case "9:16", "1:1": return 1080
        default: return 1920
        }
    }

    /// Renders one frame through the CLI on the comment's canvas (or `aspect`).
    private func renderFrame(scene: String, t: Double, comment: ReviewComment? = nil, aspect: String? = nil,
                             props: [String] = [], scale: Double? = nil, to url: URL) throws {
        let cli = try sceneCLI()
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var args = ["frame", scene, "--at", fmt(t), "--out", url.path] + canvasArgs(comment: comment, aspect: aspect) + props
        if let scale, scale < 1 { args += ["--scale", fmt(scale)] }
        try cli.runChecked(args)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError("render reported success but wrote no frame at \(url.path)")
        }
    }

    private func entry(_ id: String) throws -> ReviewEntry {
        try requireStore().resolve(id: id)
    }

    private func describe(_ e: ReviewEntry, full: Bool) -> String {
        let c = e.comment
        var head = "\(c.id) · \(e.scene) · \(c.timecode) · \(c.status.rawValue)"
        if let r = c.region { head += " · region \(r.label)" }
        head += " · by \(c.author.name)"
        if let a = c.assignee { head += " · assignee \(a.name)" }
        var lines = [head, "  " + c.body.replacingOccurrences(of: "\n", with: "\n  ")]
        if full {
            for r in c.replies {
                lines.append("  ↳ \(r.author.name)\(r.author.kind == .agent ? " (agent)" : ""): "
                             + r.body.replacingOccurrences(of: "\n", with: "\n    "))
            }
        } else if let last = c.replies.last {
            lines.append("  (\(c.replies.count) repl\(c.replies.count == 1 ? "y" : "ies"); last from \(last.author.name))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: scenes

    private func listScenes(_ a: Args) throws -> ToolResult {
        let cli = try sceneCLI()
        struct Row: Decodable { var summary: SceneSummary; var activeComments: Int; var sourcePath: String? }
        let rows: [Row]
        if project != nil {
            let r = try cli.runChecked(["review", "scenes", "--json"])
            rows = try JSONDecoder().decode([Row].self, from: Data(r.stdout.utf8))
        } else {
            let r = try cli.runChecked(["list", "--json"])
            rows = try JSONDecoder().decode([SceneSummary].self, from: Data(r.stdout.utf8))
                .map { Row(summary: $0, activeComments: 0, sourcePath: nil) }
        }
        func line(_ row: Row) -> String {
            let s = row.summary
            var line = String(format: "%@ · %@ · %.2fs", s.name, s.kind.rawValue, s.defaultDuration)
            if s.hasSoundtrack { line += " · score" }
            if s.hasProps { line += " · props" }
            if row.activeComments > 0 { line += " · \(row.activeComments) active comment(s)" }
            return line
        }
        var out = ToolResult()
        guard project == nil else {
            out.text(workspace.summary + "\n" + rows.map(line).joined(separator: "\n"))
            return out
        }
        // Standalone: the built-in templates (data-driven: change the props, not the Swift) are
        // what an agent in another codebase can use; the demo films are examples of this repo's.
        let templates = rows.filter(\.summary.hasProps)
        let demos = rows.filter { !$0.summary.hasProps }
        var text = workspace.summary + "\n\nTemplates (data-driven — get_props / set_props, then render):\n"
            + templates.map(line).joined(separator: "\n")
        if a.bool("all") ?? false {
            text += "\n\nBuilt-in demo films (examples of what scenes can do, not templates):\n"
                + demos.map { line($0) + " · demo" }.joined(separator: "\n")
        } else if !demos.isEmpty {
            text += "\n\n+ \(demos.count) built-in demo films (list_scenes {all:true} lists them)."
        }
        out.text(text)
        out.text("For a launch film of a Swift codebase: launch_film. For your own scenes: init_project, then new_scene {name}.")
        return out
    }

    private func sceneInfo(_ a: Args) throws -> ToolResult {
        let cli = try sceneCLI()
        let scene = try a.scene()
        let info = try cli.sceneInfo(scene)
        var lines = [String(format: "%@ · %@ · %.2fs · %d×%d @ %dfps", info.name, info.kind.rawValue, info.duration,
                            info.width, info.height, info.fps)]
        if let src = info.sourcePath { lines.append("source \(src)") }
        if info.clips.isEmpty { lines.append("clips: none reported (no Timeline, or not probed) — read the source") }
        for c in info.clips {
            let label = c.label ?? "Clip"
            let src = c.source.map { " \($0.file):\($0.line)" } ?? ""
            lines.append(String(format: "clip %@%.2f–%.2f %@ (in: %@)%@", String(repeating: "  ", count: c.depth),
                                c.start, c.end, label, c.transitionIn, src))
        }
        for k in info.knobs {
            let src = k.source.map { " \($0.file):\($0.line)" } ?? ""
            lines.append("knob \(k.key) = \(knobText(k.value)) (default \(knobText(k.defaultValue)))\(src)")
        }
        for c in info.captions { lines.append(String(format: "caption %.2f–%.2f %@", c.start, c.end, c.text)) }
        if !info.events.isEmpty {
            let kinds = Dictionary(grouping: info.events, by: \.kind).map { "\($0.key)×\($0.value.count)" }.sorted()
            lines.append("score: \(info.events.count) events — \(kinds.joined(separator: " "))")
            for e in info.events.prefix(80) {
                lines.append(String(format: "  %.2fs %@ %@%@", e.time, e.lane, e.kind, e.detail.map { " \($0)" } ?? ""))
            }
            if info.events.count > 80 { lines.append("  … \(info.events.count - 80) more") }
        }
        var out = ToolResult()
        out.text(lines.joined(separator: "\n"))
        if a.bool("source") ?? false {
            out.text(try sceneSource(info.sourcePath, scene: scene))
        }
        return out
    }

    /// The scene's Swift file, when it lives in the project (or the swift-render checkout).
    private func sceneSource(_ path: String?, scene: String) throws -> String {
        guard let path, path.hasSuffix(".swift") else {
            throw ToolError("\(scene) reports no source file")
        }
        let url = URL(fileURLWithPath: path).canonical
        let allowed = [project?.root, workspace.root, workspace.checkout].compactMap { $0 }
        guard allowed.contains(where: { SafePath.isInside(url, $0) }) else {
            throw ToolError("\(scene)'s source \(url.path) is outside the project — not shown")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 400_000 else { throw ToolError("\(url.path) is \(data.count / 1000) KB — too big to return") }
        return "// \(url.path)\n" + String(decoding: data, as: UTF8.self)
    }

    /// The comment named by an optional `comment` argument (its scene must match `scene`)
    /// and the optional `aspect`.
    private func canvasChoice(_ a: Args, scene: String) throws -> (comment: ReviewComment?, aspect: String?) {
        var comment: ReviewComment? = nil
        if let cid = a.optionalString("comment") {
            let e = try entry(cid)
            guard e.scene == scene else {
                throw ToolError("comment \(e.comment.id) is on \(e.scene), not \(scene)")
            }
            comment = e.comment
        }
        let aspect = a.optionalString("aspect")
        if let aspect, !["16:9", "9:16", "1:1"].contains(aspect) {
            throw ToolError("aspect must be 16:9, 9:16 or 1:1 (got \(aspect))")
        }
        return (comment, aspect)
    }

    private func renderFrames(_ a: Args) throws -> ToolResult {
        _ = try sceneCLI()
        let scene = try a.scene()
        let times = try a.doubles("times")
        guard !times.isEmpty else { throw ToolError("times must list at least one time in seconds") }
        guard times.count <= 8 else { throw ToolError("at most 8 times per call (got \(times.count))") }
        let width = min(1280, max(160, a.int("width") ?? 960))
        let (comment, aspect) = try canvasChoice(a, scene: scene)
        let props = try propsChoice(a, scene: scene, auto: comment == nil)
        let canvas = canvasWidth(comment: comment, aspect: aspect)
        var out = ToolResult()
        if let note = props.note { out.text(note) }
        for t in times {
            let url = try scratch("frame-\(scene)-\(fmt(t)).png")
            // Render near the target size: much faster than full size, same layout (scenes lay out in canvas points).
            try renderFrame(scene: scene, t: t, comment: comment, aspect: aspect, props: props.args,
                            scale: Double(width) / canvas, to: url)
            out.text(String(format: "%@ at t=%.2fs (%@)", scene, t, ReviewComment.format(t))
                     + (comment.map { " on comment \($0.id)'s canvas" } ?? aspect.map { " at \($0)" } ?? ""))
            out.png(try ReviewImage.prepare(url, region: comment?.region, maxWidth: width))
        }
        return out
    }

    private func contactSheet(_ a: Args) throws -> ToolResult {
        let cli = try sceneCLI()
        let scene = try a.scene()
        let (comment, aspect) = try canvasChoice(a, scene: scene)
        let props = try propsChoice(a, scene: scene, auto: comment == nil)
        let url = try scratch("contact-\(scene).png")
        try cli.runChecked(["contact", scene, "--out", url.path] + canvasArgs(comment: comment, aspect: aspect) + props.args)
        var out = ToolResult()
        out.text("\(scene) contact sheet (cells are evenly spaced; each is labelled with its time)"
                 + (props.note.map { "\n" + $0 } ?? ""))
        out.png(try ReviewImage.prepare(url, maxWidth: 1280))
        return out
    }

    private func checkScene(_ a: Args) throws -> ToolResult {
        let cli = try sceneCLI()
        let scene = try a.scene()
        let (comment, aspect) = try canvasChoice(a, scene: scene)
        let props = try propsChoice(a, scene: scene, auto: comment == nil)
        let url = try scratch("check-\(scene).png")
        try cli.runChecked(["check", scene, "--out", url.path] + canvasArgs(comment: comment, aspect: aspect) + props.args)
        let report = (try? String(contentsOf: url.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8))
            ?? "(no report written)"
        var out = ToolResult()
        out.text(report.trimmingCharacters(in: .whitespacesAndNewlines) + (props.note.map { "\n" + $0 } ?? ""))
        out.png(try ReviewImage.prepare(url, maxWidth: 1280))
        return out
    }

    private func build(_ a: Args) throws -> ToolResult {
        let (_, cli) = try requireProject()
        return waitFor(buildJob(cli, title: "build \(cli.product)"), a)
    }

    // MARK: comments

    private func listComments(_ a: Args) throws -> ToolResult {
        let store = try requireStore()
        let filter = try ReviewStatus.parseFilter(a.optionalString("status") ?? "active")
        var entries = store.all(status: filter).map { ReviewEntry(scene: $0.scene, comment: $0.comment) }
        if let scene = a.optionalString("scene") { entries = entries.filter { $0.scene == scene } }
        var out = ToolResult()
        if entries.isEmpty {
            out.text("No comments" + (filter.map { " with status " + $0.map(\.rawValue).sorted().joined(separator: ",") } ?? "")
                     + (a.optionalString("scene").map { " on \($0)" } ?? "") + ".")
        } else {
            out.text("\(entries.count) comment(s):\n\n" + entries.map { describe($0, full: false) }.joined(separator: "\n\n"))
        }
        // A review file that doesn't decode is skipped above — say so rather than "nothing to do".
        let broken = store.unreadableScenes()
        if !broken.isEmpty {
            out.text("warning: unreadable review file(s), their comments are not listed — "
                     + broken.map { "\($0.scene): \($0.error)" }.joined(separator: "; "))
        }
        return out
    }

    private func getComment(_ a: Args) throws -> ToolResult {
        let (_, cli) = try requireProject()
        let e = try entry(try a.string("id"))
        let c = e.comment
        var out = ToolResult()
        out.text(String(decoding: try ReviewStore.encoder.encode(e), as: UTF8.self))

        var context: [String] = []
        if let info = try? cli.sceneInfo(e.scene) {
            if let src = info.sourcePath { context.append("scene source: \(src)") }
            let active = info.clips(at: c.t)
            if active.isEmpty { context.append("clips at \(c.timecode): none reported — read the scene source") }
            for clip in active {
                context.append(String(format: "clip at t: %@%.2f–%.2f %@ (in: %@)%@",
                                     String(repeating: "  ", count: clip.depth), clip.start, clip.end,
                                     clip.label ?? "Clip", clip.transitionIn,
                                     clip.source.map { " → \($0.file):\($0.line)" } ?? ""))
            }
            if let end = c.end {
                for clip in info.clips where clip.start < end && clip.end > c.t && !clip.contains(c.t) {
                    context.append(String(format: "clip in range: %.2f–%.2f %@%@", clip.start, clip.end,
                                         clip.label ?? "Clip", clip.source.map { " → \($0.file):\($0.line)" } ?? ""))
                }
            }
        }
        if let s = c.source { context.append("clip when commented: \(s.file):\(s.line)") }
        if !context.isEmpty { out.text(context.joined(separator: "\n")) }

        do {
            let url = try scratch("comment-\(ReviewIDs.fileSafe(c.id)).png")
            try renderFrame(scene: e.scene, t: c.t, comment: c, to: url)
            out.text("Current frame at \(c.timecode)" + (c.region != nil ? " — the pink box is the commenter's region" : "")
                     + (c.end != nil ? " (start of the commented range)" : ""))
            out.png(try ReviewImage.prepare(url, region: c.region, maxWidth: 1280))
        } catch {
            out.text("(frame unavailable: \(error))")
        }
        return out
    }

    private func claimComment(_ a: Args) throws -> ToolResult {
        let store = try requireStore()
        let e = try entry(try a.string("id"))
        guard e.comment.status.isActive else {
            throw ToolError("\(e.comment.id) is \(e.comment.status.rawValue) — only open or inProgress comments can be claimed")
        }
        // Studio pre-claims for the agent run (assignee = agent); a person's claim is theirs.
        if e.comment.status == .inProgress, let who = e.comment.assignee, who.kind == .human {
            throw ToolError("\(e.comment.id) is being worked on by \(who.name) — leave it")
        }
        // Re-checked under the review lock: a person may have claimed or closed it since the read above.
        let claimed = try store.transition(scene: e.scene, id: e.comment.id, to: .inProgress, by: .agent(agentName)) { now in
            guard now.status.isActive else {
                throw ToolError("\(now.id) is \(now.status.rawValue) — only open or inProgress comments can be claimed")
            }
            if now.status == .inProgress, let who = now.assignee, who.kind == .human {
                throw ToolError("\(now.id) is being worked on by \(who.name) — leave it")
            }
        }
        var lines = ["claimed \(claimed.id) (\(e.scene) \(claimed.timecode)) → inProgress, assignee \(agentName)"]
        let existing = claimed.beforeAttachment.map { store.url(forAttachment: $0.path) }
        if let existing, FileManager.default.fileExists(atPath: existing.path) {
            lines.append("before frame: \(claimed.beforeAttachment!.path) (kept)")
        } else {
            let rel = ReviewAttachmentPaths.before(claimed.id)
            do {
                try renderFrame(scene: e.scene, t: claimed.t, comment: claimed, to: store.url(forAttachment: rel))
                try store.attach(scene: e.scene, id: claimed.id, ReviewAttachment(kind: .before, path: rel, t: claimed.t))
                lines.append("before frame: \(rel)")
            } catch {
                lines.append("before frame: not captured (\(error))")
            }
        }
        var out = ToolResult()
        out.text(lines.joined(separator: "\n"))
        return out
    }

    private func replyComment(_ a: Args) throws -> ToolResult {
        let store = try requireStore()
        let e = try entry(try a.string("id"))
        var reply = ReviewReply(author: .agent(agentName), body: try a.string("body"))
        var image: Data? = nil
        if a.bool("attach_frame") ?? false {
            let rel = ReviewAttachmentPaths.after(e.comment.id, reply: reply.id)
            let url = store.url(forAttachment: rel)
            try renderFrame(scene: e.scene, t: e.comment.t, comment: e.comment, to: url)
            reply.attachments = [ReviewAttachment(kind: .after, path: rel, t: e.comment.t)]
            image = try ReviewImage.prepare(url, region: e.comment.region, maxWidth: 960)
        }
        var updated = try store.reply(scene: e.scene, id: e.comment.id, reply)
        let reopen = (a.bool("reopen") ?? false) && updated.status == .inProgress
        if reopen {
            updated = try store.transition(scene: e.scene, id: e.comment.id, to: .open) { now in
                guard now.status == .inProgress, now.assignee?.kind != .human else {
                    throw ToolError("reply posted, but \(now.id) is \(now.status.rawValue)"
                                    + (now.assignee.map { " (assignee \($0.name))" } ?? "") + " now — not reopened")
                }
            }
        }
        var out = ToolResult()
        out.text("replied \(reply.id) on \(updated.id) (status \(reopen ? "back to" : "stays") \(updated.status.rawValue))"
                 + (reply.attachments.first.map { "; frame → \($0.path)" } ?? ""))
        if let image { out.png(image) }
        return out
    }

    private func resolveComment(_ a: Args) throws -> ToolResult {
        let store = try requireStore()
        let e = try entry(try a.string("id"))
        let summary = try a.string("summary")
        guard e.comment.status.isActive else {
            throw ToolError("\(e.comment.id) is \(e.comment.status.rawValue) — only open or inProgress comments can be resolved")
        }
        var reply = ReviewReply(author: .agent(agentName), body: summary)
        let rel = ReviewAttachmentPaths.after(e.comment.id, reply: reply.id)
        let url = store.url(forAttachment: rel)
        // Render first: a comment is only resolved against a frame that actually builds and renders.
        try renderFrame(scene: e.scene, t: e.comment.t, comment: e.comment, to: url)
        reply.attachments = [ReviewAttachment(kind: .after, path: rel, t: e.comment.t)]
        try store.reply(scene: e.scene, id: e.comment.id, reply)
        // The render above can take a while (rebuild): if a person reopened, resolved or took
        // the comment meanwhile, their change stands — the summary and frame stay as a reply.
        let done = try store.transition(scene: e.scene, id: e.comment.id, to: .resolved, by: .agent(agentName),
                                        resolution: summary) { now in
            let stillOurs = now.status == .open || (now.status == .inProgress && now.assignee?.kind != .human)
            guard stillOurs, now.status == e.comment.status else {
                throw ToolError("\(now.id) changed while rendering (now \(now.status.rawValue)"
                                + (now.assignee.map { ", assignee \($0.name)" } ?? "")
                                + ") — your summary and after frame are posted as a reply; status left as is")
            }
        }
        var out = ToolResult()
        out.text("resolved \(done.id) (\(e.scene) \(done.timecode)); after frame → \(rel)")
        out.png(try ReviewImage.prepare(url, region: e.comment.region, maxWidth: 960))
        return out
    }

    // MARK: knobs & renders

    private func setKnobs(_ a: Args) throws -> ToolResult {
        let (project, cli) = try requireProject()
        let scene = try a.scene()
        guard let values = a.raw["values"] as? JSONObject else { throw ToolError("values must be an object") }
        // Know the scene before touching the file system: a typo must not leave an orphan
        // knob file and report success.
        var info: SceneInfo? = nil
        var notes: [String] = []
        do {
            info = try cli.sceneInfo(scene)
        } catch let e as ToolError where e.description.contains("Unknown scene") {
            throw ToolError("unknown scene '\(scene)' — see list_scenes; nothing was written")
        } catch {
            notes.append("note: could not confirm \(scene) exists (\(String(describing: error).prefix(200)))")
        }
        let url = project.knobsURL(scene: scene)
        var current: [String: KnobValue]
        do {
            current = (a.bool("reset") ?? false) ? [:] : try KnobFile.loadStrict(url)
        } catch {
            throw ToolError("\(error) (pass reset: true only once the file is fixed or removed)")
        }
        let declared = Dictionary((info?.knobs ?? []).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var mistyped: [String] = []
        for (k, v) in values {
            let value: KnobValue?
            switch v {
            case is NSNull: value = nil
            case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): value = .bool(n.boolValue)
            case let n as NSNumber: value = .number(n.doubleValue)
            case let s as String: value = .string(s)
            default: throw ToolError("knob \(k): expected number, boolean, string or null")
            }
            // The engine ignores an override whose type doesn't match the declaration, so
            // saving one would report a fix that never reaches a frame.
            if let value, let knob = declared[k], let problem = Self.typeProblem(value, for: knob) {
                mistyped.append("\(k): \(problem)")
            }
            current[k] = value
        }
        guard mistyped.isEmpty else {
            throw ToolError("nothing was written — wrong value type for declared knob(s):\n  "
                            + mistyped.joined(separator: "\n  "))
        }
        try KnobFile.save(current, to: url)
        var lines = ["\(scene) knob overrides (\(url.path.replacingOccurrences(of: project.root.path + "/", with: ""))):"]
        lines += current.keys.sorted().map { "  \($0) = \(knobText(current[$0]!))" }
        if current.isEmpty { lines.append("  (none — scene defaults)") }
        lines += notes
        if let info {
            let known = Set(info.knobs.map(\.key))
            let unknown = values.keys.filter { !known.contains($0) && !(values[$0] is NSNull) }.sorted()
            if !unknown.isEmpty {
                lines.append("warning: not declared by the scene (typo?): \(unknown.joined(separator: ", "))"
                             + (known.isEmpty ? "" : " — known: \(known.sorted().joined(separator: ", "))"))
            }
        }
        var out = ToolResult()
        out.text(lines.joined(separator: "\n"))
        return out
    }

    /// Why `value` can't override `knob`, or nil when it can (mirrors the engine's coercion).
    static func typeProblem(_ value: KnobValue, for knob: KnobInfo) -> String? {
        switch (knob.kind, value) {
        case (.double, .number), (.bool, .bool), (.text, .string): return nil
        case (.color, .string(let hex)):
            var h = hex.trimmingCharacters(in: .whitespaces)
            if h.hasPrefix("#") { h.removeFirst() }
            let ok = (h.count == 6 || h.count == 8) && UInt64(h, radix: 16) != nil
            return ok ? nil : "expected a \"#RRGGBB\" or \"#RRGGBBAA\" color, got \"\(hex)\""
        case (.double, _): return "expected a number"
        case (.bool, _): return "expected true or false"
        case (.text, _): return "expected a string"
        case (.color, _): return "expected a \"#RRGGBB\" color string"
        }
    }

    private func renderVideo(_ a: Args) throws -> ToolResult {
        let cli = try sceneCLI()
        let scene = try a.scene()
        let preview = a.bool("preview") ?? false
        let aspect = try Self.aspect(a)
        // The job may start after later calls rewrote the shared scratch props: its own file.
        let tag = String(UUID().uuidString.prefix(8))
        let props = try propsChoice(a, scene: scene, auto: true, scratchTag: tag)
        let suffix = aspect.map { "-" + $0.replacingOccurrences(of: ":", with: "x") } ?? ""
        let rel = "out/\(scene)\(suffix)\(preview ? "-preview" : "").mp4"
        let base = try home()
        try Self.ensureOutDir(in: base)
        let url = base.appendingPathComponent(rel)
        let args = ["render", scene, "--out", url.path] + (aspect.map { ["--aspect", $0] } ?? [])
            + (preview ? ["--preview"] : []) + props.args + ["--progress", "json"]
        let title = "render_video \(scene)" + ([preview ? "preview" : nil, aspect].compactMap { $0 }.joined(separator: ", ")
                                                .nilIfEmpty.map { " (\($0))" } ?? "")
        let job = jobs.start(.render, title, output: url) { job in
            defer { if let f = props.scratch { try? FileManager.default.removeItem(at: f) } }
            let bound = BoundCLI(cli, cancel: job.token)
            if let p = cli as? ProjectCLI, p.freshExecutable(cancel: job.token) == nil { job.setPhase("building \(p.product)") }
            _ = try bound.executable()
            job.setPhase("rendering")
            let started = Date()
            let r = try bound.runStreaming(args, job: job) { isErr, line in
                guard isErr, let p = Self.renderProgress(line) else { return }
                job.setProgress(done: p.frame, total: p.total, fps: p.fps)
            }
            let tail = r.stdout.split(separator: "\n").suffix(4).joined(separator: "\n")
            var out = ToolResult()
            out.text(String(format: "rendered %@ in %.1fs → %@\n%@", scene, Date().timeIntervalSince(started), url.path, tail)
                     + (props.note.map { "\n" + $0 } ?? ""))
            return out
        }
        return waitFor(job, a)
    }

    /// render's `--progress json` line: {"progress":{"frame":i,"total":n,"fps":f}}.
    static func renderProgress(_ line: String) -> (frame: Double, total: Double, fps: Double?)? {
        guard line.hasPrefix("{\"progress\""),
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? JSONObject,
              let p = obj["progress"] as? JSONObject,
              let frame = (p["frame"] as? NSNumber)?.doubleValue, let total = (p["total"] as? NSNumber)?.doubleValue
        else { return nil }
        return (frame, total, (p["fps"] as? NSNumber)?.doubleValue)
    }

    /// `aspect`, validated (nil = the scene's own).
    static func aspect(_ a: Args) throws -> String? {
        let aspect = a.optionalString("aspect")
        if let aspect, !["16:9", "9:16", "1:1"].contains(aspect) {
            throw ToolError("aspect must be 16:9, 9:16 or 1:1 (got \(aspect))")
        }
        return aspect
    }

    /// `<root>/out/`; a new one gets a `*` .gitignore so films stay out of `git add -A`
    /// (what `launch` does too).
    static func ensureOutDir(in root: URL) throws {
        let out = root.appendingPathComponent("out", isDirectory: true)
        try SafePath.confined(out, root: root, sub: "out")
        guard !FileManager.default.fileExists(atPath: out.path) else { return }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try? "*\n".write(to: out.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    }
}

// MARK: - Argument access

struct Args {
    let raw: JSONObject
    init(_ raw: JSONObject) { self.raw = raw }

    func string(_ k: String) throws -> String {
        guard let s = optionalString(k), !s.isEmpty else { throw ToolError("missing required argument '\(k)'") }
        return s
    }

    /// A scene name: a Swift type name (letters, digits, `_`). Anything else — a path,
    /// "../x" — is refused before it can reach a file name.
    func scene(_ k: String = "scene") throws -> String {
        let s = try string(k)
        guard Project.isValidSceneName(s) else {
            throw ToolError("'\(s.prefix(80))' is not a scene name (Swift type names only — see list_scenes)")
        }
        return s
    }

    func optionalString(_ k: String) -> String? {
        if let s = raw[k] as? String { return s.isEmpty ? nil : s }
        if let n = raw[k] as? NSNumber { return n.stringValue }
        return nil
    }

    func double(_ k: String) -> Double? {
        if let n = raw[k] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue.isFinite ? n.doubleValue : nil }
        return (raw[k] as? String).flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil }
    }

    func int(_ k: String) -> Int? {
        if let n = raw[k] as? NSNumber { return n.intValue }
        return (raw[k] as? String).flatMap(Int.init)
    }

    func bool(_ k: String) -> Bool? {
        if let n = raw[k] as? NSNumber { return n.boolValue }
        if let s = raw[k] as? String { return ["true", "1", "yes"].contains(s.lowercased()) }
        return nil
    }

    /// Largest time in seconds a tool accepts (a day).
    static let maxSeconds = 86_400.0

    /// A number array — also tolerates a single number or "1, 2.5" (models sometimes send those).
    /// Every value must be a finite time in 0…86400 s ("nan", "inf", 1e400 are refused).
    func doubles(_ k: String) throws -> [Double] {
        func seconds(_ d: Double?) throws -> Double {
            guard let d, d.isFinite, d >= 0, d <= Self.maxSeconds else {
                throw ToolError("\(k) must be finite times in seconds, 0…\(Int(Self.maxSeconds))")
            }
            return d
        }
        switch raw[k] {
        case let list as [Any]:
            return try list.map {
                if let n = $0 as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return try seconds(n.doubleValue) }
                if let s = $0 as? String { return try seconds(Double(s.trimmingCharacters(in: .whitespaces))) }
                throw ToolError("\(k) must be numbers (seconds)")
            }
        case let n as NSNumber: return [try seconds(n.doubleValue)]
        case let s as String:
            return try s.split(separator: ",").map { try seconds(Double($0.trimmingCharacters(in: .whitespaces))) }
        default: throw ToolError("missing required argument '\(k)'")
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Shortest round-tripping text for a time ("2", "1.25") — CLI arguments and file names.
func fmt(_ d: Double) -> String {
    d == d.rounded() && abs(d) < 1e9 ? String(Int(d)) : String(d)
}

private func knobText(_ v: KnobValue) -> String {
    switch v {
    case .number(let d): return String(format: "%g", d)
    case .bool(let b): return b ? "true" : "false"
    case .string(let s): return "\"\(s)\""
    }
}
