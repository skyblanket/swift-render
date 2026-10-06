import Foundation
import SwiftRenderKit

// MARK: - MCP over stdio (JSON-RPC 2.0, one message per line)
//
// Hand-written on purpose: the surface is a handful of methods, and a dependency-free
// server builds in seconds. `tools/call` (and anything unusual) runs one at a time,
// in order, on a worker (see main.swift); `initialize`, `ping`, `tools/list` and the
// resource methods are answered at once, and `notifications/cancelled` stops the
// matching call — so a hung render never makes the server unresponsive.

typealias JSONObject = [String: Any]

enum RPCCode {
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
    /// MCP: resources/read for a uri the server doesn't have.
    static let resourceNotFound = -32002
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
    /// Sends a notification to the client (set by main.swift; nil in tests that call handle directly).
    var notify: ((JSONObject) -> Void)?

    init(tools: ToolBox, version: String) { self.tools = tools; self.version = version }

    /// `notifications/progress` for a request that carried `_meta.progressToken` (MCP: progress
    /// must increase; the token is echoed as given).
    func progressSink(_ params: JSONObject) -> ProgressSink? {
        guard let notify, let meta = params["_meta"] as? JSONObject, let token = meta["progressToken"],
              token is String || token is NSNumber else { return nil }
        let lock = NSLock()
        var last = -Double.infinity
        return { progress, total, message in
            lock.lock()
            guard progress > last else { lock.unlock(); return }
            last = progress
            lock.unlock()
            var p: JSONObject = ["progressToken": token, "progress": progress, "message": message]
            if let total { p["total"] = total }
            notify(["jsonrpc": "2.0", "method": "notifications/progress", "params": p])
        }
    }

    /// Answered on the reader thread, never queued behind a running tool call (none of
    /// them touches a CLI: the docs are compiled in).
    static let immediateMethods: Set<String> = ["initialize", "ping", "tools/list", "resources/list",
                                                "resources/templates/list", "resources/read"]

    static let resourcePrefix = "swift-render://docs/"

    /// One input line → the response to write (object or batch array), or nil for notifications.
    func handle(line: String, cancel: ProcessCancel? = nil) -> Any? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return errorResponse(id: NSNull(), code: RPCCode.parseError, message: "Parse error")
        }
        if let batch = obj as? [Any] {
            guard !batch.isEmpty else {
                return errorResponse(id: NSNull(), code: RPCCode.invalidRequest, message: "Invalid Request: empty batch")
            }
            let replies = batch.compactMap { handle(message: $0, cancel: cancel) }
            return replies.isEmpty ? nil : replies
        }
        return handle(message: obj, cancel: cancel)
    }

    func handle(message: Any, cancel: ProcessCancel? = nil) -> JSONObject? {
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
            if method == "notifications/cancelled" {
                log("cancel requested for \((params["requestId"]).map { "\($0)" } ?? "?")")
            }
            return nil
        }

        switch method {
        case "initialize":
            return response(id: id, result: initialize(params))
        case "ping":
            return response(id: id, result: [:])
        case "tools/list":
            return response(id: id, result: ["tools": tools.catalog])
        case "resources/list":
            let list: [JSONObject] = Guide.topicIDs.map { topic in
                ["uri": Self.resourcePrefix + topic, "name": topic, "title": Guide.title(topic),
                 "description": Guide.summary(topic), "mimeType": "text/markdown"]
            }
            return response(id: id, result: ["resources": list])
        case "resources/templates/list":
            return response(id: id, result: ["resourceTemplates": [] as [JSONObject]])
        case "resources/read":
            guard let uri = params["uri"] as? String else {
                return errorResponse(id: id, code: RPCCode.invalidParams, message: "resources/read needs a uri")
            }
            guard uri.hasPrefix(Self.resourcePrefix), let text = Guide.text(String(uri.dropFirst(Self.resourcePrefix.count))) else {
                return errorResponse(id: id, code: RPCCode.resourceNotFound, message: "Resource not found: \(uri.prefix(200))",
                                     data: ["uri": uri])
            }
            return response(id: id, result: ["contents": [["uri": uri, "mimeType": "text/markdown", "text": text] as JSONObject]])
        case "tools/call":
            guard let name = params["name"] as? String else {
                return errorResponse(id: id, code: RPCCode.invalidParams, message: "tools/call needs a tool name")
            }
            guard tools.has(name) else {
                return errorResponse(id: id, code: RPCCode.invalidParams, message: "Unknown tool: \(name)")
            }
            let args = params["arguments"] as? JSONObject ?? [:]
            let started = Date()
            let result = tools.call(name, args, cancel: cancel, progress: progressSink(params))
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
        let w = tools.workspace
        let mode = w.mode == .project ? "project \(w.project!.root.lastPathComponent)" : w.mode.rawValue
        return [
            "protocolVersion": chosen,
            "capabilities": ["tools": [:] as JSONObject, "resources": [:] as JSONObject],
            "serverInfo": ["name": "swift-render", "title": "swift-render (\(mode))", "version": version],
            "instructions": """
            \(Guide.recipe)
            \(w.summary)
            \(HouseRules.text)
            """,
        ]
    }

    private func response(id: Any, result: JSONObject) -> JSONObject {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func errorResponse(id: Any, code: Int, message: String, data: JSONObject? = nil) -> JSONObject {
        var error: JSONObject = ["code": code, "message": message]
        if let data { error["data"] = data }
        return ["jsonrpc": "2.0", "id": id, "error": error]
    }
}

/// stderr only — stdout carries the protocol.
func log(_ s: String) {
    FileHandle.standardError.write(Data("[swift-render-mcp] \(s)\n".utf8))
}
