// swift-render-mcp — MCP server for making and reviewing swift-render videos from any
// agent (Claude Code, Claude Desktop, Codex, Cursor, Studio's agent runner).
//
//   claude mcp add swift-render -- /path/to/swift-render-mcp     (docs/agents.md: every client)
//
// Speaks MCP (JSON-RPC 2.0, newline-delimited) on stdio. In a swift-render project
// ($SWIFT_RENDER_ROOT, or one discovered from the working directory) scene work shells
// out to the project's own CLI product, rebuilt only when sources change; anywhere else
// it uses the ready-built `swift-render` next to this binary (see Workspace.swift).
//
// Threads: this (reader) thread answers `initialize`, `ping`, `tools/list` and the
// resource methods at once and acts on `notifications/cancelled`; `render_status` runs on
// its own; everything else runs in arrival order on a serial worker. Renders, launch films
// and builds run as jobs (Jobs.swift) that outlive a call the client stops after ~60 s.
// Every CLI child has a time limit and runs in its own process group, which a cancel,
// stdin EOF or SIGTERM/SIGINT stops — no orphaned renders.
import Foundation
import SwiftRenderKit

let serverVersion = "0.10.0"

if CommandLine.arguments.contains("--version") { print(serverVersion); exit(0) }
if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
    FileHandle.standardError.write(Data("""
    swift-render-mcp — MCP stdio server: make swift-render videos (SwiftUI → MP4) from any agent.
    Project: $SWIFT_RENDER_ROOT, else the nearest swift-render project above the cwd; elsewhere
             standalone with the swift-render CLI next to this binary ($SWIFT_RENDER_CLI, then PATH).
    Tools: docs launch_film new_scene write_scene init_project get_props set_props list_scenes
           scene_info render_frames contact_sheet check_scene render_video render_status set_knobs
           build list_comments get_comment claim_comment reply_comment resolve_comment
    Resources: swift-render://docs/<topic> (the API guide).
    Jobs: render_video, launch_film, build and write_scene answer with a job id after
           SWIFT_RENDER_MCP_DETACH_AFTER seconds (default 45; 0 = always wait) and keep going;
           render_status {job} reports progress and the result.
    Time limits (seconds): SWIFT_RENDER_MCP_TIMEOUT (frames, info, sheets, init),
           SWIFT_RENDER_MCP_RENDER_TIMEOUT (render_video, launch_film), SWIFT_RENDER_MCP_BUILD_TIMEOUT.
    See docs/agents.md (setup for every client) and docs/review-loop.md.

    """.utf8))
    exit(0)
}

// fd 1 is protocol-only: keep a private copy for responses and point fd 1 at
// stderr, so nothing else in the process can corrupt the stream.
let protocolFD = dup(STDOUT_FILENO)
dup2(STDERR_FILENO, STDOUT_FILENO)
let protocolOut = FileHandle(fileDescriptor: protocolFD, closeOnDealloc: false)
signal(SIGPIPE, SIG_IGN)

let workspace = Workspace.discover()
log(workspace.summary)
let toolBox = ToolBox(workspace: workspace)
let server = MCPServer(tools: toolBox, version: serverVersion)

/// Responses come from two threads (reader and worker): one line at a time.
let sendLock = NSLock()
func send(_ message: Any) {
    guard JSONSerialization.isValidJSONObject(message),
          var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else {
        log("dropping unencodable response")
        return
    }
    data.append(0x0A)
    sendLock.lock(); defer { sendLock.unlock() }
    do { try protocolOut.write(contentsOf: data) } catch { shutdown(reason: "client went away") }
}
server.notify = { send($0) }

/// Queued and running requests, by JSON-RPC id, so `notifications/cancelled` can stop them.
final class InFlight: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: ProcessCancel] = [:]
    private var unkeyed: [ObjectIdentifier: ProcessCancel] = [:]

    static func key(_ id: Any) -> String {
        if let s = id as? String { return "s:" + s }
        if let n = id as? NSNumber { return "n:" + n.stringValue }
        return "?:\(id)"
    }

    func register(_ id: Any?, _ token: ProcessCancel) {
        lock.lock(); defer { lock.unlock() }
        if let id { tokens[Self.key(id)] = token } else { unkeyed[ObjectIdentifier(token)] = token }
    }

    func remove(_ id: Any?, _ token: ProcessCancel) {
        lock.lock(); defer { lock.unlock() }
        if let id, tokens[Self.key(id)] === token { tokens[Self.key(id)] = nil }
        unkeyed[ObjectIdentifier(token)] = nil
    }

    func cancel(_ id: Any) -> Bool {
        lock.lock(); let token = tokens[Self.key(id)]; lock.unlock()
        token?.cancel()
        return token != nil
    }

    func cancelAll(hard: Bool = false) {
        lock.lock(); let all = Array(tokens.values) + Array(unkeyed.values); lock.unlock()
        for t in all { t.cancel(hard: hard) }
    }
}

let inFlight = InFlight()
let worker = DispatchQueue(label: "swift-render-mcp.tools")
let pending = DispatchGroup()

/// Stop every child process group, then exit. Safe from any thread.
func shutdown(reason: String) -> Never {
    log("shutting down (\(reason))")
    inFlight.cancelAll()                       // SIGTERM to each running child's process group
    toolBox.jobs.cancelAll()                   // …and each job's (renders that outlived their call)
    usleep(300_000)
    inFlight.cancelAll(hard: true)             // SIGKILL for anything that ignored it
    toolBox.jobs.cancelAll(hard: true)
    exit(0)
}

// SIGTERM / SIGINT (Claude Code or Studio stopping the server): stop children first.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    src.setEventHandler { shutdown(reason: "signal \(sig)") }
    src.resume()
    signalSources.append(src)
}

while let line = readLine(strippingNewline: true) {
    if line.allSatisfy(\.isWhitespace) { continue }
    let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8), options: [.fragmentsAllowed])) as? JSONObject
    if let message, let method = message["method"] as? String {
        if message["id"] == nil {
            // Notifications never queue: a cancel must reach a call that is running now.
            if method == "notifications/cancelled", let params = message["params"] as? JSONObject,
               let target = params["requestId"] {
                if !inFlight.cancel(target) { log("cancel for \(target): not in flight") }
            }
            _ = server.handle(message: message)
            continue
        }
        if MCPServer.immediateMethods.contains(method) {
            if let response = server.handle(message: message) { send(response) }
            continue
        }
    }
    // tools/call, unknown methods, batches and parse errors: in order, on the worker —
    // except render_status, which only reads the job board and may wait on a job, so it
    // never queues behind (or holds up) the worker.
    let token = ProcessCancel()
    let id = message?["id"]
    let concurrent = message?["method"] as? String == "tools/call"
        && ((message?["params"] as? JSONObject)?["name"] as? String).map(ToolBox.concurrentTools.contains) == true
    inFlight.register(id, token)
    pending.enter()
    (concurrent ? DispatchQueue.global() : worker).async {
        defer { inFlight.remove(id, token); pending.leave() }
        // MCP: a cancelled request gets no response.
        guard !token.isCancelled else { log("skipped cancelled request \(id.map { "\($0)" } ?? "")"); return }
        let response = server.handle(line: line, cancel: token)
        guard !token.isCancelled else { log("dropped response to cancelled request \(id.map { "\($0)" } ?? "")"); return }
        if let response { send(response) }
    }
}

// stdin closed: finish what was already asked (a piped script expects its answers),
// but never wait on a stuck child for long — then stop whatever is left.
let grace = ProcessInfo.processInfo.environment["SWIFT_RENDER_MCP_EOF_GRACE"].flatMap(Double.init) ?? 30
let deadline = Date().addingTimeInterval(grace)
if pending.wait(timeout: .now() + grace) == .timedOut {
    shutdown(reason: String(format: "stdin closed; calls still running after %.0fs", grace))
}
// Jobs that outlived their calls: no one can collect them now, but a piped script's film
// may be nearly done — same grace, then stop them.
if !toolBox.jobs.waitAll(max(0, deadline.timeIntervalSinceNow)) {
    shutdown(reason: String(format: "stdin closed; jobs still running after %.0fs", grace))
}
exit(0)
