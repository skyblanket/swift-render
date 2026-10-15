//
//  Speech.swift — voiceover as Score events.
//
//  `speak("…", at: t)` renders the line with a local TTS engine the first time,
//  stores it in ~/Library/Caches/swift-render/tts/<sha>.{caf,wav}, and replays the
//  cached file forever after — renders stay deterministic and only the first
//  pass pays for synthesis. The same cached audio drives CaptionTrack timings.
//
import CryptoKit
import Foundation

/// Local text-to-speech engines.
public enum TTSEngine: Sendable, Hashable {
    /// macOS `say` — always available. `voice` is any name from `say -v '?'`
    /// (install Premium/Enhanced voices in System Settings › Accessibility ›
    /// Spoken Content for much better quality). `wpm` ≈ 170–200 sounds natural.
    case say(voice: String? = nil, wpm: Int? = nil)
    /// Kokoro (tools/kokoro_tts.py) — higher quality, needs `.venv-kokoro`
    /// (or SWIFT_RENDER_KOKORO_PYTHON). Voices like "af_heart", "am_michael".
    case kokoro(voice: String = "af_heart")

    var tag: String {
        switch self {
        case .say(let v, let w): return "say|\(v ?? "default")|\(w.map(String.init) ?? "default")"
        case .kokoro(let v): return "kokoro|\(v)"
        }
    }
}

/// One voiceover line: the text and the TTS engine that speaks it.
public struct SpeechSpec: Sendable, Hashable {
    /// The words to speak.
    public var text: String
    /// The engine (and voice) that renders the line.
    public var engine: TTSEngine
    /// Creates a line spoken by `engine` (macOS `say` by default).
    public init(_ text: String, engine: TTSEngine = .say()) {
        self.text = text; self.engine = engine
    }
}

/// Errors thrown when a TTS engine fails.
public enum SpeechError: Error, CustomStringConvertible {
    case engineFailed(String)
    /// Human-readable error message.
    public var description: String {
        switch self { case .engineFailed(let why): return "TTS failed: \(why)" }
    }
}

/// Renders voiceover lines with a local TTS engine and caches the audio.
public enum Speech {
    /// Where rendered lines are cached (~/Library/Caches/swift-render/tts).
    public static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("swift-render/tts", isDirectory: true)
    }

    static func key(_ spec: SpeechSpec) -> String {
        let digest = SHA256.hash(data: Data("\(spec.engine.tag)\n\(spec.text)".utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func cachedURL(_ spec: SpeechSpec) -> URL {
        let ext: String
        switch spec.engine { case .say: ext = "caf"; case .kokoro: ext = "wav" }
        return cacheDirectory.appendingPathComponent("\(key(spec)).\(ext)")
    }

    /// Path of the rendered line, synthesizing it if needed.
    @discardableResult
    public static func render(_ spec: SpeechSpec) throws -> URL {
        try prepare([spec])
        return cachedURL(spec)
    }

    /// Decoded audio for a line (cached in memory after first load).
    public static func buffer(_ spec: SpeechSpec) throws -> SampleBuffer {
        try SampleLibrary.load(url: render(spec))
    }

    /// Synthesize every uncached line. Kokoro lines are batched into one model load.
    public static func prepare(_ specs: [SpeechSpec]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let missing = Array(Set(specs)).filter { !fm.fileExists(atPath: cachedURL($0).path) }
        var kokoro: [String: [SpeechSpec]] = [:]
        for spec in missing {
            switch spec.engine {
            case .say(let voice, let wpm): try say(spec, voice: voice, wpm: wpm)
            case .kokoro(let voice): kokoro[voice, default: []].append(spec)
            }
        }
        for (voice, lines) in kokoro { try kokoroBatch(lines, voice: voice) }
    }

    private static func say(_ spec: SpeechSpec, voice: String?, wpm: Int?) throws {
        let out = cachedURL(spec)
        let tmpText = FileManager.default.temporaryDirectory.appendingPathComponent("sr-tts-\(UUID().uuidString).txt")
        let tmpOut = cacheDirectory.appendingPathComponent(".\(key(spec))-\(UUID().uuidString).caf")
        try spec.text.write(to: tmpText, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpText) }
        var args: [String] = []
        if let voice { args += ["-v", voice] }
        if let wpm { args += ["-r", String(wpm)] }
        args += ["-o", tmpOut.path, "--data-format=LEF32@44100", "-f", tmpText.path]
        try run("/usr/bin/say", args)
        try FileManager.default.moveItem(at: tmpOut, to: out)
    }

    private static func kokoroBatch(_ lines: [SpeechSpec], voice: String) throws {
        let root = AssetPaths.packageRoot
        let python = ProcessInfo.processInfo.environment["SWIFT_RENDER_KOKORO_PYTHON"]
            ?? root.appendingPathComponent(".venv-kokoro/bin/python").path
        let script = root.appendingPathComponent("tools/kokoro_tts.py").path
        guard FileManager.default.isExecutableFile(atPath: python) else {
            throw SpeechError.engineFailed("Kokoro python not found at \(python) — set SWIFT_RENDER_KOKORO_PYTHON or use .say()")
        }
        let tsv = lines.map { "\(key($0))\t0\t\($0.text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " "))" }
            .joined(separator: "\n") + "\n"
        let tsvURL = FileManager.default.temporaryDirectory.appendingPathComponent("sr-kokoro-\(UUID().uuidString).tsv")
        try tsv.write(to: tsvURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tsvURL) }
        try run(python, [script, tsvURL.path, cacheDirectory.path, voice])
        for spec in lines where !FileManager.default.fileExists(atPath: cachedURL(spec).path) {
            throw SpeechError.engineFailed("kokoro produced no file for “\(spec.text.prefix(40))”")
        }
    }

    private static func run(_ exe: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { throw SpeechError.engineFailed("\(exe): \(error.localizedDescription)") }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw SpeechError.engineFailed("\((exe as NSString).lastPathComponent) exited \(p.terminationStatus): \(msg.prefix(300))")
        }
    }

    /// Where speech actually sounds inside the rendered line (leading/trailing
    /// silence trimmed), in seconds from the line's start.
    public static func voicedSpan(_ b: SampleBuffer) -> (start: Double, end: Double) {
        let win = Int(scoreSampleRate * 0.01)
        guard b.frames > win else { return (0, b.duration) }
        var levels: [Float] = []
        var i = 0
        while i + win <= b.frames {
            var s: Float = 0
            for j in i..<(i + win) { s += b.left[j] * b.left[j] + b.right[j] * b.right[j] }
            levels.append((s / Float(2 * win)).squareRoot())
            i += win
        }
        let peak = levels.max() ?? 0
        guard peak > 0 else { return (0, b.duration) }
        let thr = peak * 0.06
        let first = levels.firstIndex { $0 > thr } ?? 0
        let last = levels.lastIndex { $0 > thr } ?? (levels.count - 1)
        return (Double(first * win) / scoreSampleRate, Double((last + 1) * win) / scoreSampleRate)
    }
}
