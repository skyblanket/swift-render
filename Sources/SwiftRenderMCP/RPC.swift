import Foundation

// MARK: - MCP over stdio (JSON-RPC 2.0, one message per line)
//
// Hand-written on purpose: the surface is four methods, and a dependency-free
// server builds in seconds. Requests are handled one at a time, in order.

typealias JSONObject = [String: Any]

enum RPCCode {
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
}

/// What a tool hands back: MCP content blocks plus the error flag.
struct ToolResult {
    var content: [JSONObject] = []
    var isError = false

    static func error(_ text: String) -> ToolResult {
        var r = ToolResult(); r.text(text); r.isError = true; return r
    }

    mutating func text(_ s: String) { content.append(["type": "text", "text": s]) }

    mutating func png(_ data: Data) {
        content.append(["type": "image", "data": data.base64EncodedString(), "mimeType": "image/png"])
    }

    var json: JSONObject { ["content": content, "isError": isError] }
}

/// A tool failure the model should see (becomes `isError: true` + text, never a protocol error).
struct ToolError: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}

final class MCPServer {
    /// Newest last; an unknown client version gets the newest.
    static let supportedVersions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]

    let tools: ToolBox
    let version: String

    init(tools: ToolBox, version: String) { self.tools = tools; self.version = version }

    /// One input line → the response to write (object or batch array), or nil for notifications.
    func handle(line: String) -> Any? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return errorResponse(id: NSNull(), code: RPCCode.parseError, message: "Parse error")
        }
        if let batch = obj as? [Any] {
            guard !batch.isEmpty else {
                return errorResponse(id: NSNull(), code: RPCCode.invalidRequest, message: "Invalid Request: empty batch")
            }
            let replies = batch.compactMap { handle(message: $0) }
            return replies.isEmpty ? nil : replies
        }
        return handle(message: obj)
    }

    func handle(message: Any) -> JSONObject? {
        guard let msg = message as? JSONObject else {
            return errorResponse(id: NSNull(), code: RPCCode.invalidRequest, message: "Invalid Request")
        }
        let id = msg["id"]
        guard let method = msg["method"] as? String else {
            // A response to a request we never send, or junk: answer junk only if it has an id.
            if msg["result"] != nil || msg["error"] != nil || id == nil { return nil }
            return errorResponse(id: id!, code: RPCCode.invalidRequest, message: "Invalid Request: no method")
        }
        let params = msg["params"] as? JSONObject ?? [:]

        // Notifications (no id) never get a response, whatever the method.
        guard let id else {
            if method == "notifications/initialized" { log("client initialized") }
            return nil
        }

        switch method {
        case "initialize":
            return response(id: id, result: initialize(params))
        case "ping":
            return response(id: id, result: [:])
        case "tools/list":
            return response(id: id, result: ["tools": tools.catalog])
        case "tools/call":
            guard let name = params["name"] as? String else {
                return errorResponse(id: id, code: RPCCode.invalidParams, message: "tools/call needs a tool name")
            }
            guard tools.has(name) else {
                return errorResponse(id: id, code: RPCCode.invalidParams, message: "Unknown tool: \(name)")
            }
            let args = params["arguments"] as? JSONObject ?? [:]
            let started = Date()
            let result = tools.call(name, args)
            log(String(format: "%@ %@ in %.2fs", name, result.isError ? "failed" : "ok", Date().timeIntervalSince(started)))
            return response(id: id, result: result.json)
        default:
            return errorResponse(id: id, code: RPCCode.methodNotFound, message: "Method not found: \(method)")
        }
    }

    private func initialize(_ params: JSONObject) -> JSONObject {
        let asked = params["protocolVersion"] as? String
        let chosen = asked.flatMap { Self.supportedVersions.contains($0) ? $0 : nil } ?? Self.supportedVersions.last!
        if let client = params["clientInfo"] as? JSONObject {
            log("initialize from \(client["name"] ?? "?") \(client["version"] ?? "") protocol \(asked ?? "?") → \(chosen)")
        }
        return [
            "protocolVersion": chosen,
            "capabilities": ["tools": [:] as JSONObject],
            "serverInfo": ["name": "swift-render", "title": "swift-render review loop", "version": version],
            "instructions": """
            swift-render renders SwiftUI scenes (pure functions of time) to video. Reviewers leave \
            timecoded, optionally region-boxed comments; you address them: list_comments → get_comment \
            (frame + region + clip source) → claim_comment → edit the scene's Swift → build → render_frames \
            to look at the result → resolve_comment (or reply_comment with a question and leave it open).
            """,
        ]
    }

    private func response(id: Any, result: JSONObject) -> JSONObject {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func errorResponse(id: Any, code: Int, message: String) -> JSONObject {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message] as JSONObject]
    }
}

/// stderr only — stdout carries the protocol.
func log(_ s: String) {
    FileHandle.standardError.write(Data("[swift-render-mcp] \(s)\n".utf8))
}
