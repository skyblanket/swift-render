import Foundation
import SwiftRenderKit

// MARK: - Jobs: long work that outlives a tool call
//
// Some clients stop a tool call after about 60 s whatever the server does (Claude Desktop,
// the Claude Code desktop app, cursor-agent; progress notifications don't reset them) and
// then cancel it, which would kill the render. So renders, launch films and builds run as
// jobs on their own queue, one at a time. The tool call waits for its job up to
// `Jobs.detachAfter` (45 s), then answers with the job id and the planned output and lets
// the job finish; `render_status {job}` reports progress and, once done, the job's result
// (the same text and images the tool would have returned). `wait: true` blocks until done
// (clients without a cap), `wait: false` answers at once.

enum Jobs {
    /// Seconds a call waits for its job before answering with the job id.
    /// `SWIFT_RENDER_MCP_DETACH_AFTER=0` never detaches (always waits).
    static var detachAfter: TimeInterval {
        let v = ProcessInfo.processInfo.environment["SWIFT_RENDER_MCP_DETACH_AFTER"].flatMap(Double.init) ?? 45
        return v <= 0 ? .infinity : v
    }

    /// The longest a `render_status` call waits (stays under the clients' ~60 s cap).
    static var statusWaitCap: TimeInterval { min(50, detachAfter.isFinite ? detachAfter : 50) }
}

/// Reports progress to the client while a call waits (`notifications/progress`, sent only
/// when the request carried `_meta.progressToken`).
typealias ProgressSink = (_ progress: Double, _ total: Double?, _ message: String) -> Void

final class Job: @unchecked Sendable {
    enum Kind: String { case render, launch, build }
    enum State: String { case queued, running, done, failed, cancelled }

    let id: String
    let kind: Kind
    /// "render_video PebbleTeaser (preview, 9:16)"
    let title: String
    let created = Date()
    /// Stops ProcessRunner children (builds, scans, sheets).
    let token = ProcessCancel()

    private let lock = NSLock()
    private let group = DispatchGroup()
    private var _state: State = .queued
    private var _output: URL?
    private var _phase = "queued"
    private var _done = 0.0, _total = 0.0
    private var _fps: Double?
    private var _started: Date?
    private var _finished: Date?
    private var _result: ToolResult?
    /// Streaming children (StreamingRunner), stopped by `cancel`.
    private var pids: [Int32] = []
    private var cancelled = false

    init(id: String, kind: Kind, title: String, output: URL?) {
        self.id = id; self.kind = kind; self.title = title; self._output = output
        group.enter()
    }

    private func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }

    var state: State { locked { _state } }
    var isFinished: Bool { locked { [.done, .failed, .cancelled].contains(_state) } }
    var isCancelled: Bool { locked { cancelled } }
    var result: ToolResult? { locked { _result } }
    /// Where the job writes its film (known up front for render_video; for launch_film once scanned).
    var output: URL? {
        get { locked { _output } }
        set { locked { _output = newValue } }
    }

    func setPhase(_ s: String) { locked { _phase = s } }

    /// Frames (or percent) done of total; `fps` when the CLI reports it.
    func setProgress(done: Double, total: Double, fps: Double? = nil) {
        locked { _done = done; _total = total; if let fps { _fps = fps } }
    }

    /// (done, total) for notifications/progress, total nil when unknown.
    var progress: (Double, Double?) { locked { (_done, _total > 0 ? _total : nil) } }

    func markRunning() { locked { _state = .running; _started = Date(); if _phase == "queued" { _phase = "starting" } } }

    func finish(_ state: State, _ result: ToolResult) {
        locked { _state = state; _result = result; _finished = Date() }
        group.leave()
    }

    /// true when finished within `seconds`.
    func wait(_ seconds: TimeInterval) -> Bool {
        if seconds <= 0 { return isFinished }
        return group.wait(timeout: seconds.isFinite ? .now() + seconds : .distantFuture) == .success
    }

    /// Stops the job: its ProcessRunner children and streaming children (process groups).
    func cancel(hard: Bool = false) {
        let running: [Int32] = locked { cancelled = true; return pids }
        token.cancel(hard: hard)
        for pid in running {
            if hard { kill(-pid, SIGKILL); kill(pid, SIGKILL) } else { ProcessRunner.terminateGroup(pid) }
        }
    }

    /// false when already cancelled (the runner then stops the child itself).
    func attach(_ pid: Int32) -> Bool { locked { guard !cancelled else { return false }; pids.append(pid); return true } }
    func detach(_ pid: Int32) { locked { pids.removeAll { $0 == pid } } }

    /// One line: "j3 render_video Teaser (preview) · running · rendering 1200/2790 frames, 31 fps, ~50s left · 41s"
    var statusLine: String {
        locked {
            let now = Date()
            var parts = ["\(id) \(title)", _state.rawValue]
            switch _state {
            case .queued: parts.append("starts when the jobs before it finish")
            case .running:
                var p = _phase
                if _total > 0 {
                    if kind == .launch {
                        p += String(format: " %.0f%%", _done / _total * 100)
                    } else {
                        p += String(format: " %.0f/%.0f frames", _done, _total)
                        if let fps = _fps, fps > 0 {
                            p += String(format: ", %.0f fps, ~%.0fs left", fps, max(0, (_total - _done) / fps))
                        }
                    }
                }
                parts.append(p)
                if let s = _started { parts.append(String(format: "%.0fs", now.timeIntervalSince(s))) }
            case .done, .failed, .cancelled:
                if let s = _started, let f = _finished { parts.append(String(format: "took %.0fs", f.timeIntervalSince(s))) }
            }
            if let o = _output { parts.append("→ \(o.path)") }
            return parts.joined(separator: " · ")
        }
    }
}

/// Every job this server started (the last 30), run one at a time in start order.
final class JobBoard: @unchecked Sendable {
    private let queue = DispatchQueue(label: "swift-render-mcp.jobs")
    private let lock = NSLock()
    private var jobs: [Job] = []
    private var counter = 0

    func start(_ kind: Job.Kind, _ title: String, output: URL? = nil,
               body: @escaping (Job) throws -> ToolResult) -> Job {
        lock.lock()
        counter += 1
        let job = Job(id: "j\(counter)", kind: kind, title: title, output: output)
        jobs.append(job)
        // Forget old finished jobs, never running ones.
        while jobs.count > 30, let i = jobs.firstIndex(where: \.isFinished) { jobs.remove(at: i) }
        lock.unlock()
        log("job \(job.id) queued: \(title)")
        queue.async {
            guard !job.isCancelled else {
                job.finish(.cancelled, .error("\(job.id) \(title) was cancelled before it started")); return
            }
            job.markRunning()
            let started = Date()
            do {
                let r = try body(job)
                job.finish(job.isCancelled ? .cancelled : r.isError ? .failed : .done, r)
            } catch {
                job.finish(job.isCancelled ? .cancelled : .failed, .error(String(describing: error)))
            }
            log(String(format: "job %@ %@ in %.1fs", job.id, job.state.rawValue, Date().timeIntervalSince(started)))
        }
        return job
    }

    func job(_ id: String) -> Job? {
        lock.lock(); defer { lock.unlock() }
        let key = id.trimmingCharacters(in: .whitespaces).lowercased()
        return jobs.first { $0.id == key || $0.id == "j" + key }
    }

    var all: [Job] { lock.lock(); defer { lock.unlock() }; return jobs }

    /// The unfinished job of `kind`, if any (a second build would only wait on SwiftPM's lock).
    func unfinished(_ kind: Job.Kind) -> Job? { all.last { $0.kind == kind && !$0.isFinished } }

    func cancelAll(hard: Bool = false) { for j in all where !j.isFinished { j.cancel(hard: hard) } }

    /// true when every job finished within `seconds`.
    func waitAll(_ seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        for j in all where !j.isFinished {
            if !j.wait(max(0, deadline.timeIntervalSinceNow)) { return false }
        }
        return true
    }

    /// Waits for `job` as a tool call: until done, until `budget` runs out (→ an answer that
    /// names the job), or until the call is cancelled — which stops the job too when
    /// `stopJobOnCancel` (the client gave up before it was handed a job id). Sends progress
    /// while it waits.
    func waitFor(_ job: Job, budget: TimeInterval, cancel: ProcessCancel?, stopJobOnCancel: Bool = true,
               progress: ProgressSink?, detached: (Job, TimeInterval) -> ToolResult) -> ToolResult {
        let start = Date()
        var lastSent = -1.0
        while true {
            let left = budget - Date().timeIntervalSince(start)
            if job.wait(min(0.5, max(0, left))), let r = job.result { return r }
            if cancel?.isCancelled ?? false {
                if stopJobOnCancel { job.cancel() }
                return .error("\(job.id): the call was cancelled")
            }
            if let progress {
                let (done, total) = job.progress
                let value = total.map { _ in done } ?? Date().timeIntervalSince(start)
                if value > lastSent {
                    lastSent = value
                    progress(value, total, job.statusLine)
                }
            }
            if Date().timeIntervalSince(start) >= budget { return detached(job, Date().timeIntervalSince(start)) }
        }
    }
}

// MARK: - A child whose output arrives while it runs

/// ProcessRunner, but stdout/stderr lines reach `onLine` as they are written (render's
/// `--progress json`, launch's percent) and the child is registered with a Job so
/// `render_status {cancel}` and shutdown stop its process group.
struct StreamResult { var status: Int32; var stdout: String; var stderr: String }

enum StreamingRunner {
    static func run(_ executable: String, _ args: [String], cwd: URL, environment: [String: String]? = nil,
                    timeout: TimeInterval, job: Job, onLine: @escaping (_ stderr: Bool, _ line: String) -> Void) throws -> StreamResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.currentDirectoryURL = cwd
        if let environment { p.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice

        final class Collector: @unchecked Sendable {
            let lock = NSLock()
            var all = Data()
            var pending = Data()
            let isErr: Bool
            let onLine: (Bool, String) -> Void
            init(isErr: Bool, onLine: @escaping (Bool, String) -> Void) { self.isErr = isErr; self.onLine = onLine }
            func add(_ d: Data) {
                lock.lock()
                all.append(d); pending.append(d)
                var lines: [String] = []
                // `\r` too: launch redraws its percent in place.
                while let i = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                    lines.append(String(decoding: pending[pending.startIndex..<i], as: UTF8.self))
                    pending = Data(pending[(i + 1)...])
                }
                lock.unlock()
                for l in lines where !l.isEmpty { onLine(isErr, l) }
            }
            var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: all, as: UTF8.self) }
        }
        let outC = Collector(isErr: false, onLine: onLine), errC = Collector(isErr: true, onLine: onLine)
        let group = DispatchGroup()
        for (pipe, c) in [(out, outC), (err, errC)] {
            group.enter()
            let h = pipe.fileHandleForReading
            DispatchQueue.global().async {
                while true {
                    let d = h.availableData
                    if d.isEmpty { break }
                    c.add(d)
                }
                group.leave()
            }
        }
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        let start = Date()
        do { try p.run() } catch {
            try? out.fileHandleForWriting.close(); try? err.fileHandleForWriting.close()
            throw error
        }
        let pid = p.processIdentifier
        let attached = job.attach(pid)
        defer { job.detach(pid) }
        if !attached { ProcessRunner.terminateGroup(pid) }

        var timedOut = false
        while exited.wait(timeout: .now() + 0.2) == .timedOut {
            if job.isCancelled || job.token.isCancelled { ProcessRunner.terminateGroup(pid); exited.wait(); break }
            if Date().timeIntervalSince(start) > timeout {
                timedOut = true
                ProcessRunner.terminateGroup(pid)
                exited.wait()
                break
            }
        }
        let stopped = timedOut || !attached || job.isCancelled || job.token.isCancelled
        if group.wait(timeout: .now() + (stopped ? 2 : 3600)) == .timedOut {
            try? out.fileHandleForReading.close(); try? err.fileHandleForReading.close()
        }
        if timedOut { throw ProcessRunnerError.timedOut(seconds: timeout) }
        if stopped { throw ProcessRunnerError.cancelled }
        return StreamResult(status: p.terminationStatus, stdout: outC.text, stderr: errC.text)
    }
}
