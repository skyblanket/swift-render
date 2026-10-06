import Foundation
import XCTest

/// A line-oriented JSON-RPC client over swift-render-mcp's stdio (MCPServerTests, MCPCreateTests).
final class MCPTestClient: @unchecked Sendable {
    let process = Process()
    private let input = Pipe(), output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var replies: [String: [String: Any]] = [:]
    private var _notifications: [[String: Any]] = []
    private var nextID = 1000

    /// Server → client notifications (e.g. notifications/progress) received so far.
    var notifications: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return _notifications }

    /// `env` is merged over this process's environment; `cwd` is the server's working directory.
    init(_ bin: URL, env: [String: String], cwd: URL? = nil) throws {
        process.executableURL = bin
        process.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        if let cwd { process.currentDirectoryURL = cwd }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self, !d.isEmpty else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.buffer.append(d)
            while let nl = self.buffer.firstIndex(of: 0x0A) {
                let line = self.buffer[self.buffer.startIndex..<nl]
                self.buffer = Data(self.buffer[(nl + 1)...])
                if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    if let id = obj["id"] { self.replies["\(id)"] = obj }
                    else if obj["method"] != nil { self._notifications.append(obj) }
                }
            }
        }
        try process.run()
    }

    func send(_ obj: [String: Any]) {
        var data = try! JSONSerialization.data(withJSONObject: obj)
        data.append(0x0A)
        input.fileHandleForWriting.write(data)
    }

    func call(_ id: Int, _ tool: String, _ args: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": tool, "arguments": args]])
    }

    func reply(_ id: Int, within seconds: Double) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            lock.lock(); let r = replies["\(id)"]; lock.unlock()
            if let r { return r }
            usleep(20_000)
        } while Date() < deadline
        return nil
    }

    /// Sends a request and waits for its reply.
    func request(_ method: String, _ params: [String: Any]? = nil, within seconds: Double = 30) -> [String: Any]? {
        lock.lock(); nextID += 1; let id = nextID; lock.unlock()
        var msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { msg["params"] = params }
        send(msg)
        return reply(id, within: seconds)
    }

    /// tools/call and wait: (isError, joined text, image count).
    func tool(_ name: String, _ args: [String: Any] = [:], within seconds: Double = 60) -> (isError: Bool, text: String, images: Int) {
        let r = request("tools/call", ["name": name, "arguments": args], within: seconds)
        let res = r?["result"] as? [String: Any] ?? [:]
        let content = (res["content"] as? [[String: Any]]) ?? []
        return (res["isError"] as? Bool ?? true,
                content.compactMap { $0["text"] as? String }.joined(separator: "\n"),
                content.filter { $0["type"] as? String == "image" }.count)
    }

    func initialize() -> [String: Any]? {
        request("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:] as [String: Any],
                               "clientInfo": ["name": "t", "version": "1"]], within: 10)?["result"] as? [String: Any]
    }

    func closeInput() { try? input.fileHandleForWriting.close() }

    func stop() {
        if process.isRunning { process.terminate() }
        output.fileHandleForReading.readabilityHandler = nil
    }
}
