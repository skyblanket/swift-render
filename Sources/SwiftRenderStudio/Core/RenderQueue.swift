import Foundation
import Observation
import SwiftRenderKit

// MARK: - Render queue
//
// Exports run one at a time through the project's own CLI, never the preview host:
//
//   build    optimized → `swift build -c release --product <p> --scratch-path .build/studio`
//            current debug → the executable the live host runs (no build)
//   render   `<exe> render <Scene> <preset flags> [--range a:b] [--knobs f] [--props f] --progress json`
//            stderr `{"progress":{…}}` lines drive the bar and ETA
//   finish   GIF: ffmpeg palette pass. In→Out range with a score: `<exe> audio` + ffmpeg mux,
//            because the CLI skips the audio mux for ranges.
//
// Cancel = SIGINT, SIGTERM after 2 s, SIGKILL after 4 s; partial output and scratch
// files are deleted. Live knob/props values are snapshotted into files at enqueue,
// so moving a slider mid-export doesn't change the export.

/// What the queue needs from the project window when a job is enqueued.
struct RenderInputs: Sendable {
    var knobs: [String: KnobValue] = [:]
    var propsJSON: String?
    /// The executable the live host runs (`currentDebug` builds reuse it).
    var debugExecutable: URL?
    var hasSoundtrack = false
    /// Length of the scene (nil when unknown, e.g. not the selected scene).
    var duration: Double?
}

struct RenderJob: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case queued
        /// Latest build line, e.g. "[12/40] Compiling SwiftRender NeverHeard.swift".
        case building(String)
        case rendering(done: Int, total: Int, fps: Double)
        /// Post-processing (GIF palette, audio mux).
        case finishing(String)
        case finished(seconds: Double)
        case failed(String)
        case cancelled
    }

    let id: UUID
    var scene: String
    var preset: RenderPreset
    var range: ClosedRange<Double>?
    var build: BuildChoice
    var knobs: KnobChoice
    var output: URL
    var state: State = .queued
    var createdAt = Date()
    var startedAt: Date?
    /// Snapshot of live values at enqueue (`knobs == .useLive`).
    var liveKnobs: [String: KnobValue]?
    var propsJSON: String?
    var hasSoundtrack = false
    var debugExecutable: URL?
    /// Last lines of CLI / build / ffmpeg output, for the failure tooltip.
    var log: [String] = []
    /// Output size on disk once finished.
    var bytes: Int64?

    var isActive: Bool {
        switch state {
        case .building, .rendering, .finishing: return true
        default: return false
        }
    }

    var isDone: Bool {
        switch state {
        case .finished, .failed, .cancelled: return true
        default: return false
        }
    }

    /// 0…1 while rendering, nil when indeterminate.
    var fraction: Double? {
        if case .rendering(let d, let t, _) = state, t > 0 { return min(1, Double(d) / Double(t)) }
        if case .finishing = state { return 1 }
        return nil
    }

    /// Seconds left at the current throughput.
    var eta: Double? {
        guard case .rendering(let d, let t, let fps) = state, fps > 0, d > 0 else { return nil }
        return Double(max(0, t - d)) / fps
    }

    /// The span of scene time the export covers.
    var durationLabel: String {
        if let r = range { return "\(StudioStyle.timecode(r.lowerBound))–\(StudioStyle.timecode(r.upperBound))" }
        return "whole scene"
    }
}

enum RenderQueueError: Error, CustomStringConvertible {
    case build(String)
    case missingExecutable
    var description: String {
        switch self {
        case .build(let s): return s
        case .missingExecutable: return "No built CLI yet — wait for the first build, or choose Optimized."
        }
    }
}

@MainActor @Observable
final class RenderQueue {
    /// Builds (or finds) the CLI for a configuration; reports progress lines.
    typealias ExecutableResolver = @Sendable (_ project: Project, _ configuration: String,
                                              _ progress: @escaping @Sendable (String) -> Void) async throws -> URL

    let project: Project
    private(set) var jobs: [RenderJob] = []
    /// Remembered across launches for ⌘R.
    var lastPreset: RenderPreset = RenderPreset.remembered {
        didSet { RenderPreset.remembered = lastPreset }
    }
    /// ffmpeg from the login shell's PATH (GIF export, audio for In→Out ranges); nil until resolved.
    private(set) var ffmpeg: URL?
    private(set) var ffmpegResolved = false
    /// Bumped when a render lands on disk (the sidebar's RENDERS list re-reads).
    private(set) var outputsVersion = 0

    /// Wired by ProjectModel: live knobs/props and the host's executable.
    @ObservationIgnored var inputs: (@MainActor (_ scene: String) -> RenderInputs)?
    @ObservationIgnored var resolveExecutable: ExecutableResolver
    @ObservationIgnored private var running: [UUID: Running] = [:]
    @ObservationIgnored private var pumpTask: Task<Void, Never>?

    /// Handles to cancel the job that's running.
    private final class Running {
        var task: Task<Void, Never>?
        var child: ChildProcess?
        var cancelled = false
    }

    init(project: Project, resolveExecutable: ExecutableResolver? = nil, ffmpeg: URL?? = nil) {
        self.project = project
        self.resolveExecutable = resolveExecutable ?? RenderQueue.swiftPM
        if let ffmpeg {
            self.ffmpeg = ffmpeg
            ffmpegResolved = true
        } else {
            Task { [weak self] in
                let found = await Task.detached(priority: .utility) { ToolPaths.resolveBlocking("ffmpeg") }.value
                self?.ffmpeg = found
                self?.ffmpegResolved = true
            }
        }
    }

    /// Release (or debug) build in Studio's scratch path, so the export uses the
    /// same module cache as the live builds and never fights the terminal's lock.
    static let swiftPM: ExecutableResolver = { project, configuration, progress in
        let scratch = RenderQueue.realPath(project.root).appendingPathComponent(".build/studio", isDirectory: true)
        let (events, cancel) = ProjectBuilder.stream(project, configuration: configuration, scratchPath: scratch)
        return try await withTaskCancellationHandler {
            for await e in events {
                switch e {
                case .progress(let line): progress(line)
                case .waitingForLock: progress("Waiting for another swift build…")
                case .diagnostic: break
                case .finished(let r):
                    if r.success, let exe = r.executable { return exe }
                    let first = r.errors.first.map { "\(URL(fileURLWithPath: $0.file).lastPathComponent):\($0.line): \($0.message)" }
                        ?? r.log.split(separator: "\n").last(where: { $0.contains("error") }).map(String.init)
                        ?? "build failed"
                    throw RenderQueueError.build("\(configuration.capitalized) build failed — \(first)")
                }
            }
            throw CancellationError()
        } onCancel: {
            cancel.cancel()
        }
    }

    /// `BuildController.canonical` off the main actor: the scratch path must be spelled
    /// exactly like the live builds' or SwiftPM's module cache rejects it.
    nonisolated static func realPath(_ url: URL) -> URL {
        guard let p = realpath(url.path, nil) else { return url }
        defer { free(p) }
        return URL(fileURLWithPath: String(cString: p), isDirectory: true)
    }

    // MARK: Queries

    var active: RenderJob? { jobs.first { $0.isActive } }
    var pending: [RenderJob] { jobs.filter { $0.state == .queued } }
    /// Jobs not yet done (toolbar badge).
    var outstanding: Int { jobs.filter { !$0.isDone }.count }

    func job(_ id: RenderJob.ID) -> RenderJob? { jobs.first { $0.id == id } }

    /// `out/<Scene>-<tag>-<yyyyMMdd-HHmm>.<ext>`, suffixed `-2`, `-3`… when taken.
    static func defaultOutput(project: Project, scene: String, preset: RenderPreset, date: Date = Date(),
                              taken: Set<String> = []) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        let base = "\(scene)-\(preset.fileTag)-\(f.string(from: date))"
        var url = project.rendersDir.appendingPathComponent("\(base).\(preset.fileExtension)")
        var n = 2
        while taken.contains(url.path) || FileManager.default.fileExists(atPath: url.path) {
            url = project.rendersDir.appendingPathComponent("\(base)-\(n).\(preset.fileExtension)")
            n += 1
        }
        return url
    }

    func defaultOutput(scene: String, preset: RenderPreset) -> URL {
        Self.defaultOutput(project: project, scene: scene, preset: preset,
                           taken: Set(jobs.filter { !$0.isDone }.map(\.output.path)))
    }

    /// Why a job can't run as configured (shown in the sheet; also enforced at enqueue).
    static func problem(preset: RenderPreset, duration: Double?, range: ClosedRange<Double>?,
                        ffmpegAvailable: Bool) -> String? {
        if preset.isGIF && !ffmpegAvailable { return "GIF export needs ffmpeg (brew install ffmpeg)." }
        if let range { return preset.durationProblem(range.upperBound - range.lowerBound) }
        if let duration { return preset.durationProblem(duration) }
        return nil
    }

    // MARK: Enqueue / cancel

    @discardableResult
    func enqueue(scene: String, preset: RenderPreset, range: ClosedRange<Double>?, build: BuildChoice,
                 knobs: KnobChoice, output: URL? = nil) -> RenderJob.ID {
        lastPreset = preset
        let input = inputs?(scene) ?? RenderInputs()
        var job = RenderJob(id: UUID(), scene: scene, preset: preset, range: range, build: build, knobs: knobs,
                            output: output ?? defaultOutput(scene: scene, preset: preset))
        job.liveKnobs = knobs == .useLive && !input.knobs.isEmpty ? input.knobs : nil
        job.propsJSON = input.propsJSON
        job.hasSoundtrack = input.hasSoundtrack
        job.debugExecutable = input.debugExecutable
        if let why = Self.problem(preset: preset, duration: input.duration, range: range,
                                  ffmpegAvailable: !ffmpegResolved || ffmpeg != nil) {
            job.state = .failed(why)
        }
        jobs.append(job)
        pump()
        return job.id
    }

    func cancel(_ id: RenderJob.ID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch jobs[i].state {
        case .queued:
            jobs[i].state = .cancelled
        case .building, .rendering, .finishing:
            guard let r = running[id] else { return }
            r.cancelled = true
            r.task?.cancel()                // stops a build
            if let child = r.child { Task { await child.terminate() } }
        default: break
        }
    }

    /// Drops finished, failed and cancelled rows from the activity list.
    func clearDone() { jobs.removeAll { $0.isDone } }

    // MARK: Running

    private func pump() {
        guard active == nil, running.isEmpty, let next = jobs.first(where: { $0.state == .queued }) else { return }
        let r = Running()
        running[next.id] = r
        update(next.id) { $0.startedAt = Date(); $0.state = .building("Preparing…") }
        r.task = Task { [weak self] in
            await self?.execute(next.id, r)
            guard let self else { return }
            self.running[next.id] = nil
            self.pump()
        }
    }

    private func update(_ id: RenderJob.ID, _ edit: (inout RenderJob) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        edit(&jobs[i])
    }

    private func appendLog(_ id: RenderJob.ID, _ line: String) {
        update(id) {
            $0.log.append(line)
            if $0.log.count > 40 { $0.log.removeFirst($0.log.count - 40) }
        }
    }

    private func execute(_ id: RenderJob.ID, _ r: Running) async {
        guard let job = job(id) else { return }
        let fm = FileManager.default
        let scratch = project.cacheDir.appendingPathComponent("renders", isDirectory: true)
        let tag = id.uuidString.prefix(8)
        var temps: [URL] = []
        func finish(_ state: RenderJob.State) {
            temps.forEach { try? fm.removeItem(at: $0) }
            if case .finished = state {
                let size = (try? fm.attributesOfItem(atPath: job.output.path)[.size] as? NSNumber)?.int64Value
                update(id) { $0.bytes = size }
                outputsVersion += 1
            } else {
                try? fm.removeItem(at: job.output)       // partial file
            }
            update(id) { $0.state = r.cancelled ? .cancelled : state }
        }

        // 1. Executable.
        let exe: URL
        do {
            if job.build == .currentDebug, let debug = job.debugExecutable, fm.isExecutableFile(atPath: debug.path) {
                exe = debug
            } else {
                let config = job.build == .optimized ? "release" : "debug"
                update(id) { $0.state = .building(config == "release" ? "Building release…" : "Building…") }
                exe = try await resolveExecutable(project, config) { [weak self] line in
                    Task { @MainActor in
                        guard let self, case .building = self.job(id)?.state else { return }
                        self.update(id) { $0.state = .building(line) }
                    }
                }
            }
        } catch {
            finish(.failed(error is CancellationError ? "Cancelled" : "\(error)"))
            return
        }
        if r.cancelled { finish(.cancelled); return }
        if job.preset.isGIF {
            while !ffmpegResolved { try? await Task.sleep(for: .milliseconds(50)) }
            guard ffmpeg != nil else { finish(.failed("GIF export needs ffmpeg (brew install ffmpeg).")); return }
        }

        // 2. Inputs snapshotted to files.
        var extra: [String] = []
        do {
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            try fm.createDirectory(at: job.output.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let knobs = job.liveKnobs {
                let url = scratch.appendingPathComponent("\(tag)-knobs.json")
                try KnobFile.save(knobs, to: url)
                temps.append(url)
                extra += ["--knobs", url.path]
            }
            if let props = job.propsJSON {
                let url = scratch.appendingPathComponent("\(tag)-props.json")
                try Data(props.utf8).write(to: url)
                temps.append(url)
                extra += ["--props", url.path]
            }
        } catch {
            finish(.failed("Couldn't write render inputs: \(error.localizedDescription)"))
            return
        }

        // 3. Render. GIFs and scored ranges render to scratch first.
        let muxAudio = job.range != nil && job.hasSoundtrack && !job.preset.isGIF && ffmpeg != nil
        let videoOut = job.preset.isGIF || muxAudio ? scratch.appendingPathComponent("\(tag)-video.mp4") : job.output
        if videoOut != job.output { temps.append(videoOut) }
        var args = job.preset.args(scene: job.scene, out: videoOut)
        if let range = job.range {
            args += ["--range", String(format: "%.4f:%.4f", range.lowerBound, range.upperBound)]
        }
        args += extra + ["--progress", "json"]
        update(id) { $0.state = .rendering(done: 0, total: 0, fps: 0) }
        let status = await runChild(id, r, exe, args, progress: true)
        if r.cancelled { finish(.cancelled); return }
        guard status == 0, fm.fileExists(atPath: videoOut.path) else {
            finish(.failed(failureLine(id, fallback: "render exited \(status)")))
            return
        }

        // 4. Finish.
        if let ffmpeg, job.preset.isGIF {
            update(id) { $0.state = .finishing("Encoding GIF…") }
            let s = await runChild(id, r, ffmpeg, RenderPreset.gifArgs(input: videoOut, output: job.output))
            if r.cancelled { finish(.cancelled); return }
            guard s == 0 else { finish(.failed(failureLine(id, fallback: "ffmpeg exited \(s)"))); return }
        } else if let ffmpeg, muxAudio, let range = job.range {
            update(id) { $0.state = .finishing("Adding the score…") }
            let wav = scratch.appendingPathComponent("\(tag)-score.wav")
            temps.append(wav)
            var a = await runChild(id, r, exe, ["audio", job.scene, "--out", wav.path] + extra)
            if a == 0, !r.cancelled {
                a = await runChild(id, r, ffmpeg, RenderPreset.muxArgs(video: videoOut, audio: wav, start: range.lowerBound,
                                                                       end: range.upperBound, output: job.output))
            }
            if r.cancelled { finish(.cancelled); return }
            if a != 0 {
                // The picture is fine; ship it silent rather than lose the export.
                appendLog(id, "audio mux failed; kept the silent render")
                try? fm.removeItem(at: job.output)
                try? fm.moveItem(at: videoOut, to: job.output)
            }
        }
        finish(.finished(seconds: Date().timeIntervalSince(self.job(id)?.startedAt ?? Date())))
    }

    /// Runs a child to exit, feeding output to the job log (and `--progress json` to its state).
    private func runChild(_ id: RenderJob.ID, _ r: Running, _ exe: URL, _ args: [String], progress: Bool = false) async -> Int32 {
        let child = ChildProcess(exe, args, cwd: project.root, env: ToolPaths.environment, qos: .userInitiated)
        r.child = child
        defer { r.child = nil }
        do { try child.run() } catch {
            appendLog(id, "couldn't start \(exe.lastPathComponent): \(error.localizedDescription)")
            return -1
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in
                for await line in child.stderrLines {
                    guard let self else { continue }
                    if progress, let p = try? HostWire.decode(RenderProgressLine.self, line: line) {
                        self.update(id) { $0.state = .rendering(done: p.progress.frame, total: p.progress.total, fps: p.progress.fps) }
                    } else {
                        self.appendLog(id, String(decoding: line, as: UTF8.self))
                    }
                }
            }
            group.addTask { @MainActor [weak self] in
                for await line in child.stdoutLines {
                    guard let self else { continue }
                    let text = String(decoding: line, as: UTF8.self)
                    // "[swift-render] scene=… frames=540 → out" — the total before the first progress line.
                    if progress, let total = Self.parseFrames(text) {
                        self.update(id) {
                            if case .rendering(0, 0, _) = $0.state { $0.state = .rendering(done: 0, total: total, fps: 0) }
                        }
                    }
                    self.appendLog(id, text)
                }
            }
        }
        // Not cancellable: `cancel` terminates the child, which ends this wait.
        return await child.waitForExit().status
    }

    static func parseFrames(_ line: String) -> Int? {
        guard let r = line.range(of: " frames=") else { return nil }
        return Int(line[r.upperBound...].prefix { $0.isNumber })
    }

    private func failureLine(_ id: RenderJob.ID, fallback: String) -> String {
        let log = job(id)?.log ?? []
        return log.last(where: { $0.localizedCaseInsensitiveContains("error") })
            ?? log.last(where: { !$0.hasPrefix("[swift-render]") }) ?? fallback
    }

    // MARK: Outputs

    /// Finished renders on disk (sidebar), newest first.
    func recentOutputs(limit: Int = 8) -> [URL] {
        _ = outputsVersion
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: project.rendersDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { ["mp4", "mov", "gif"].contains($0.pathExtension.lowercased()) }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
            .prefix(limit).map { $0 }
    }

    /// Project-relative path when the file is inside the project (review attachments are).
    func relativePath(_ url: URL) -> String {
        let root = project.root.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        return p.hasPrefix(root + "/") ? String(p.dropFirst(root.count + 1)) : p
    }

    /// Replies to a comment with the finished render as a `.video` attachment.
    @discardableResult
    func attach(_ id: RenderJob.ID, toComment commentID: String, author: String) throws -> ReviewComment {
        guard let job = job(id), case .finished = job.state else { throw ReviewError.io("render isn't finished") }
        var body = "Rendered \(job.preset.title) (\(job.preset.sizeLabel) @ \(job.preset.fps)"
        if let r = job.range { body += ", \(StudioStyle.timecode(r.lowerBound))–\(StudioStyle.timecode(r.upperBound))" }
        body += "): \(relativePath(job.output))"
        let reply = ReviewReply(author: ReviewAuthor(name: author), body: body,
                                attachments: [ReviewAttachment(kind: .video, path: relativePath(job.output),
                                                               t: job.range?.lowerBound)])
        return try ReviewStore(project: project).reply(scene: job.scene, id: commentID, reply)
    }

    /// Active comments on a scene (the "Attach to Comment" menu).
    func attachableComments(scene: String) -> [ReviewComment] {
        let file = try? ReviewStore(project: project).load(scene: scene)
        return (file?.comments ?? []).filter { $0.status.isActive }.sorted { $0.t < $1.t }
    }
}
