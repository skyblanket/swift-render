import Foundation
import SwiftRenderKit

// MARK: - Child processes
//
// One wrapper for every child Studio runs: render hosts, `swift build`, `claude`,
// export renders. Text streams are split on raw bytes (a multi-byte character cut
// across reads stays intact) and handlers are cleared on EOF (an empty
// `availableData` would otherwise busy-loop). Host stdout is "raw": the owner
// reads it with blocking read(2) on its own thread (binary frames).

final class ChildProcess: @unchecked Sendable {
    struct Termination: Sendable, Equatable {
        var status: Int32
        var uncaughtSignal: Bool
    }

    let executable: URL
    let arguments: [String]
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let rawStdout: Bool
    private let writeQueue = DispatchQueue(label: "studio.child.stdin")
    private let lock = NSLock()
    private var exitWaiters: [CheckedContinuation<Termination, Never>] = []
    private var _termination: Termination?
    private var tail = Data()
    private let stderrDrained = DispatchSemaphore(value: 0)
    private static let tailLimit = 64 * 1024

    /// Newline-delimited stdout lines (empty stream when `rawStdout`).
    let stdoutLines: AsyncStream<Data>
    /// Newline-delimited stderr lines (newest 2000 buffered).
    let stderrLines: AsyncStream<Data>
    private let stdoutCont: AsyncStream<Data>.Continuation
    private let stderrCont: AsyncStream<Data>.Continuation

    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    init(_ executable: URL, _ arguments: [String], cwd: URL, env: [String: String],
         qos: QualityOfService = .userInitiated, rawStdout: Bool = false) {
        _ = Self.ignoreSIGPIPE      // a dead child's stdin must give EPIPE, not kill Studio
        self.executable = executable
        self.arguments = arguments
        self.rawStdout = rawStdout
        (stdoutLines, stdoutCont) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(2000))
        (stderrLines, stderrCont) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(2000))
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = env
        process.qualityOfService = qos
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    /// Raw stdout for owners that frame it themselves (`rawStdout: true`).
    var stdoutHandle: FileHandle { stdoutPipe.fileHandleForReading }

    var termination: Termination? { lock.lock(); defer { lock.unlock() }; return _termination }

    /// Last ≤64 KB of stderr (crash reports, build failures).
    var stderrTail: String { lock.lock(); defer { lock.unlock() }; return String(decoding: tail, as: UTF8.self) }

    func run() throws {
        if rawStdout { stdoutCont.finish() } else { attachLines(stdoutPipe.fileHandleForReading, stdoutCont, keepTail: false) }
        attachLines(stderrPipe.fileHandleForReading, stderrCont, keepTail: true)
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            let t = Termination(status: p.terminationStatus, uncaughtSignal: p.terminationReason == .uncaughtSignal)
            // Let the stderr reader drain whatever the dying process wrote last (the
            // crash report) before anyone reads `stderrTail`.
            _ = self.stderrDrained.wait(timeout: .now() + 0.5)
            self.lock.lock()
            self._termination = t
            let waiters = self.exitWaiters
            self.exitWaiters = []
            self.lock.unlock()
            waiters.forEach { $0.resume(returning: t) }
        }
        try process.run()
    }

    private func attachLines(_ handle: FileHandle, _ cont: AsyncStream<Data>.Continuation, keepTail: Bool) {
        var buffer = LineBuffer()
        let drained = keepTail ? stderrDrained : nil
        handle.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard !chunk.isEmpty else {
                h.readabilityHandler = nil
                cont.finish()
                drained?.signal()
                return
            }
            if keepTail, let self { self.lock.lock(); self.appendTail(chunk); self.lock.unlock() }
            for line in buffer.append(chunk) { cont.yield(line) }
        }
    }

    /// Caller holds `lock`.
    private func appendTail(_ d: Data) {
        tail.append(d)
        if tail.count > Self.tailLimit { tail.removeFirst(tail.count - Self.tailLimit) }
    }

    /// Ordered stdin write; errors (EPIPE after the child died) are reported, not fatal.
    func write(_ data: Data, completion: (@Sendable (Error?) -> Void)? = nil) {
        let h = stdinPipe.fileHandleForWriting
        writeQueue.async {
            do { try h.write(contentsOf: data); completion?(nil) } catch { completion?(error) }
        }
    }

    func closeStdin() {
        let h = stdinPipe.fileHandleForWriting
        writeQueue.async { try? h.close() }
    }

    /// SIGINT — lets `swift build` / `claude` cancel their own children.
    func interrupt() { if process.isRunning { process.interrupt() } }

    func kill() { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }

    /// SIGINT, then SIGTERM after `grace`, then SIGKILL after another `grace`.
    func terminate(grace: Duration = .seconds(2)) async {
        guard process.isRunning else { return }
        process.interrupt()
        if await waitForExit(timeout: grace) != nil { return }
        process.terminate()
        if await waitForExit(timeout: grace) != nil { return }
        kill()
        _ = await waitForExit()
    }

    func waitForExit() async -> Termination {
        await withCheckedContinuation { c in
            lock.lock()
            if let t = _termination { lock.unlock(); c.resume(returning: t); return }
            exitWaiters.append(c)
            lock.unlock()
        }
    }

    /// nil on timeout. Polls: a timed-out continuation could never be cancelled cleanly.
    func waitForExit(timeout: Duration) async -> Termination? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let t = termination { return t }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return termination
    }
}

