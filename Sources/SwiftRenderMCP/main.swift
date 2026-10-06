// swift-render-mcp — MCP server for the review loop (Claude Code, Studio's agent runner).
//
//   claude mcp add swift-render -- swift-render-mcp        (or the repo's .mcp.json)
//
// Speaks MCP (JSON-RPC 2.0, newline-delimited) on stdio. The project is
// $SWIFT_RENDER_ROOT, else discovered from the working directory. Scene work
// shells out to the project's own CLI product, rebuilt only when sources change.
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

func send(_ message: Any) {
    guard JSONSerialization.isValidJSONObject(message),
          var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else {
        log("dropping unencodable response")
        return
    }
    data.append(0x0A)
    do { try protocolOut.write(contentsOf: data) } catch { exit(0) }    // client went away
}

while let line = readLine(strippingNewline: true) {
    if line.allSatisfy(\.isWhitespace) { continue }
    if let response = server.handle(line: line) { send(response) }
}
exit(0)
