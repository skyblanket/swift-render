// swift-render-mcp — MCP server for the review loop (Claude Code, Studio's agent runner).
//
//   claude mcp add swift-render -- swift-render-mcp        (or the repo's .mcp.json)
//
// Speaks MCP (JSON-RPC 2.0, newline-delimited) on stdio. The project is
// $SWIFT_RENDER_ROOT, else discovered from the working directory. Scene work
// shells out to the project's own CLI product, rebuilt only when sources change.
//
// Threads: this (reader) thread answers `initialize`, `ping` and `tools/list` at once
// and acts on `notifications/cancelled`; everything else runs in arrival order on a
// serial worker. Every CLI child has a time limit and runs in its own process group,
// which a cancel, stdin EOF or SIGTERM/SIGINT stops — no orphaned renders.
import Foundation
import SwiftRenderKit

let serverVersion = "0.10.0"

if CommandLine.arguments.contains("--version") { print(serverVersion); exit(0) }
if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
    FileHandle.standardError.write(Data("""
    swift-render-mcp — MCP stdio server for swift-render review comments and renders.
    Project: $SWIFT_RENDER_ROOT, else the nearest swift-render.json / Package.swift above the cwd.
    Tools: list_scenes scene_info render_frames contact_sheet check_scene build list_comments
           get_comment claim_comment reply_comment resolve_comment set_knobs render_video
    Time limits (seconds): SWIFT_RENDER_MCP_TIMEOUT (frames, info, sheets),
           SWIFT_RENDER_MCP_RENDER_TIMEOUT (render_video), SWIFT_RENDER_MCP_BUILD_TIMEOUT.
    See docs/review-loop.md.

    """.utf8))
    exit(0)
}

// fd 1 is protocol-only: keep a private copy for responses and point fd 1 at
// stderr, so nothing else in the process can corrupt the stream.
let protocolFD = dup(STDOUT_FILENO)
dup2(STDERR_FILENO, STDOUT_FILENO)
let protocolOut = FileHandle(fileDescriptor: protocolFD, closeOnDealloc: false)
signal(SIGPIPE, SIG_IGN)

let project = Project.discover()
if let project {
    log("project \(project.root.path) · product \(project.config.product)")
} else {
    log("no project found from \(FileManager.default.currentDirectoryPath); tools will report it")
}
let server = MCPServer(tools: ToolBox(project: project), version: serverVersion)

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
    usleep(300_000)
    inFlight.cancelAll(hard: true)             // SIGKILL for anything that ignored it
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
    // tools/call, unknown methods, batches and parse errors: in order, on the worker.
    let token = ProcessCancel()
    let id = message?["id"]
    inFlight.register(id, token)
    pending.enter()
    worker.async {
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
if pending.wait(timeout: .now() + grace) == .timedOut {
    shutdown(reason: String(format: "stdin closed; calls still running after %.0fs", grace))
}
exit(0)
