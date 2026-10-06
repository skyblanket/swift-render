import Foundation

// MARK: - Claude Code stream-json
//
// `claude -p --output-format stream-json --verbose` prints one JSON object per line:
// `system/init` (session, model, MCP servers), `assistant` (text + tool_use blocks),
// `user` (tool_result blocks), `stream_event` (partial deltas, ignored), and a final
// `result`. The schema moves between releases, so this reads `[String: Any]` with
// optionals everywhere and skips anything it doesn't recognize. Success is decided
// by `result.is_error`, not `subtype`: a not-logged-in run ends with
// `subtype: "success", is_error: true` (docs/review-loop.md).

struct ClaudeStreamDecoder {
    /// Project root, so summaries show `Sources/…/Scene.swift`, not absolute paths.
    var root: String?
    private(set) var sessionID: String?
    /// A `result` line arrived (the run reported its own end).
    private(set) var sawResult = false

    init(root: String? = nil) { self.root = root.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 } }

    /// Tool names that change files (their `file_path` feeds checkpoints and diff stats).
    static let writingTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    mutating func decode(_ line: Data) -> [AgentEvent] {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return [] }
        switch obj["type"] as? String {
        case "system": return system(obj)
        case "assistant": return assistant(obj)
        case "user": return user(obj)
        case "result": return result(obj)
        default: return []
        }
    }

    mutating func decode(_ line: String) -> [AgentEvent] { decode(Data(line.utf8)) }

    // MARK: Line types

    private mutating func system(_ o: [String: Any]) -> [AgentEvent] {
        switch o["subtype"] as? String {
        case "init":
            let sid = o["session_id"] as? String ?? ""
            sessionID = sid
            let servers = o["mcp_servers"] as? [[String: Any]] ?? []
            // Project/inline config: "swift-render"; plugin: "plugin:swift-render:swift-render".
            let ours = servers.first { ($0["name"] as? String).map { $0 == "swift-render" || $0.hasSuffix(":swift-render") } ?? false }
            let status = ours?["status"] as? String
            var out: [AgentEvent] = [.started(sessionID: sid, model: o["model"] as? String, mcpStatus: status)]
            if !servers.isEmpty, status != "connected" {
                out.append(.notice(status.map { "swift-render MCP server is \($0) — review tools may be missing" }
                                   ?? "swift-render MCP server isn't configured for this session"))
            }
            return out
        case "api_retry":
            let attempt = (o["attempt"] as? NSNumber)?.intValue
            return [.notice("API error, retrying" + (attempt.map { " (attempt \($0))" } ?? ""))]
        case "compact_boundary":
            return [.notice("Context compacted")]
        default:
            return []
        }
    }

    private func assistant(_ o: [String: Any]) -> [AgentEvent] {
        let message = o["message"] as? [String: Any]
        var out: [AgentEvent] = []
        for block in Self.blocks(message?["content"]) {
            switch block["type"] as? String {
            case "text":
                let t = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(.text(t)) }
            case "tool_use":
                out.append(.tool(Self.toolCall(id: block["id"] as? String ?? "",
                                               name: block["name"] as? String ?? "tool",
                                               input: block["input"] as? [String: Any] ?? [:], root: root)))
            default:
                break       // thinking, redacted_thinking, server tool blocks
            }
        }
        return out
    }

    private func user(_ o: [String: Any]) -> [AgentEvent] {
        let message = o["message"] as? [String: Any]
        return Self.blocks(message?["content"]).compactMap { block in
            guard block["type"] as? String == "tool_result" else { return nil }
            let isError = (block["is_error"] as? NSNumber)?.boolValue ?? false
            return .toolResult(id: block["tool_use_id"] as? String ?? "", ok: !isError,
                               summary: Self.resultSummary(block["content"]))
        }
    }

    private mutating func result(_ o: [String: Any]) -> [AgentEvent] {
        sawResult = true
        let subtype = o["subtype"] as? String
        let ok = !((o["is_error"] as? NSNumber)?.boolValue ?? (subtype != "success"))
        var out: [AgentEvent] = []
        for d in o["permission_denials"] as? [[String: Any]] ?? [] {
            let name = Self.shortName(d["tool_name"] as? String ?? "tool")
            out.append(.notice("Permission denied: \(name)"))
        }
        var text = o["result"] as? String
        if !ok, text?.isEmpty ?? true {
            let errors = (o["errors"] as? [Any])?.compactMap { $0 as? String } ?? []
            text = errors.isEmpty ? subtype.map { "Ended: \($0)" } : errors.joined(separator: "\n")
        }
        let seconds = (o["duration_ms"] as? NSNumber).map { $0.doubleValue / 1000 } ?? 0
        out.append(.finished(ok: ok, costUSD: (o["total_cost_usd"] as? NSNumber)?.doubleValue,
                             seconds: seconds, result: text))
        return out
    }

    // MARK: Helpers

    /// `content` is an array of blocks, or (for plain prompts) a string.
    private static func blocks(_ content: Any?) -> [[String: Any]] {
        if let a = content as? [[String: Any]] { return a }
        if let s = content as? String { return [["type": "text", "text": s]] }
        return []
    }

    /// `mcp__swift-render__get_comment` / `mcp__plugin_swift-render_swift-render__get_comment` → `get_comment`.
    static func shortName(_ name: String) -> String {
        guard name.hasPrefix("mcp__"), let r = name.range(of: "__", options: .backwards) else { return name }
        return String(name[r.upperBound...])
    }

    static func toolCall(id: String, name: String, input: [String: Any], root: String?) -> AgentToolCall {
        let short = shortName(name)
        func str(_ k: String) -> String? { (input[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func rel(_ p: String) -> String {
            guard let root, p.hasPrefix(root + "/") else { return p }
            return String(p.dropFirst(root.count + 1))
        }
        var call = AgentToolCall(id: id, name: short, summary: "")
        switch short {
        case "Read", "Edit", "Write", "MultiEdit", "NotebookEdit":
            let path = str("file_path") ?? str("notebook_path") ?? ""
            call.files = path.isEmpty ? [] : [path]
            call.writes = writingTools.contains(short)
            call.summary = rel(path)
            if short == "Read", let off = (input["offset"] as? NSNumber)?.intValue { call.summary += ":\(off)" }
            if short == "Edit", (input["replace_all"] as? NSNumber)?.boolValue == true { call.summary += " (all)" }
        case "Bash":
            call.summary = firstLine(str("command") ?? str("description") ?? "")
        case "Glob", "Grep":
            call.summary = [str("pattern"), str("path").map(rel)].compactMap { $0 }.joined(separator: " in ")
        case "render_frames":
            let times = (input["times"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
            call.summary = (str("scene") ?? "") + (times.isEmpty ? "" : " @ " + times.map { trim($0) + "s" }.joined(separator: ", "))
        case "get_comment", "claim_comment":
            call.summary = str("id") ?? ""
        case "reply_comment":
            call.summary = [str("id"), str("body").map { "“\(firstLine($0))”" }].compactMap { $0 }.joined(separator: " ")
        case "resolve_comment":
            call.summary = [str("id"), str("summary").map { "“\(firstLine($0))”" }].compactMap { $0 }.joined(separator: " ")
        case "list_comments":
            call.summary = [str("scene"), str("status")].compactMap { $0 }.joined(separator: " · ")
        case "set_knobs":
            let keys = (input["values"] as? [String: Any]).map { $0.keys.sorted().joined(separator: ", ") } ?? ""
            call.summary = [str("scene"), keys.isEmpty ? nil : keys].compactMap { $0 }.joined(separator: ": ")
        case "Task", "Agent":
            call.summary = str("description") ?? ""
        case "TodoWrite":
            call.summary = "\((input["todos"] as? [Any])?.count ?? 0) todos"
        default:
            call.summary = str("scene") ?? str("id") ?? compact(input)
        }
        return call
    }

    /// First non-empty line of a tool result (text blocks), plus an image count.
    static func resultSummary(_ content: Any?) -> String {
        var texts: [String] = []
        var images = 0
        if let s = content as? String { texts.append(s) }
        for b in content as? [[String: Any]] ?? [] {
            switch b["type"] as? String {
            case "text": if let t = b["text"] as? String { texts.append(t) }
            case "image": images += 1
            default: break
            }
        }
        let line = firstLine(texts.joined(separator: "\n"))
        let pics = images == 0 ? "" : "\(images) image\(images == 1 ? "" : "s")"
        return [line, pics].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func firstLine(_ s: String, limit: Int = 160) -> String {
        let line = s.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    private static func trim(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(format: "%g", d)
    }

    private static func compact(_ input: [String: Any]) -> String {
        guard !input.isEmpty, let d = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]) else { return "" }
        return firstLine(String(decoding: d, as: UTF8.self), limit: 120)
    }
}
