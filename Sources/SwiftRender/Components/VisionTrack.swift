import AVFoundation
import CoreImage
import CryptoKit
import SwiftUI
import Vision

// MARK: - Data

/// A tracked point in normalized frame coordinates: (0,0) top-left, (1,1) bottom-right.
public struct VisionPoint: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var confidence: Double
    public init(x: Double, y: Double, confidence: Double) { self.x = x; self.y = y; self.confidence = confidence }
    public func at(_ size: CGSize) -> CGPoint { CGPoint(x: x * Double(size.width), y: y * Double(size.height)) }
}

/// Everything Vision found in one video frame.
public struct VisionFrame: Codable, Sendable {
    public var time: Double
    /// Body joints by name: nose, neck, leftShoulder … rightAnkle, root (see `VisionTrack.bones`).
    public var body: [String: VisionPoint]
    /// Up to two hands; joints by name: wrist, thumbTip, indexTip, middleTip, ringTip, littleTip, …
    public var hands: [[String: VisionPoint]]

    public init(time: Double, body: [String: VisionPoint] = [:], hands: [[String: VisionPoint]] = []) {
        self.time = time; self.body = body; self.hands = hands
    }
    public var hasPerson: Bool { !body.isEmpty }
}

// MARK: - Track

/// Apple Vision run over a video **once** — body pose, hand pose and a person mask per
/// frame — then read back as a pure function of time, like `AudioTrack`.
///
///     static let track = VisionTrack.load("me-dancing.mov")       // analyzes + caches on first use
///     …
///     let pose = track.frame(at: t)                               // nearest analyzed frame
///     PoseOverlay(pose, size: size)                               // skeleton + hands
///     track.mask(at: t)                                           // CGImage, white = person
///
/// Results are cached in `~/Library/Caches/swift-render/vision` keyed by the file's
/// path, size, modification date and the sample rate — later renders (and every
/// `--jobs` process) read the cache, so output is stable across runs.
public final class VisionTrack: @unchecked Sendable {
    public let fps: Double
    public let frames: [VisionFrame]
    public let maskSize: (width: Int, height: Int)
    private let maskBytes: Data                      // frames × w × h, 8-bit
    private var maskCache: [Int: CGImage] = [:]
    private let lock = NSLock()

    public init(fps: Double, frames: [VisionFrame], maskSize: (Int, Int) = (0, 0), maskBytes: Data = Data()) {
        self.fps = fps; self.frames = frames; self.maskSize = (maskSize.0, maskSize.1); self.maskBytes = maskBytes
    }

    public var duration: Double { Double(frames.count) / fps }

    public func index(at t: Double) -> Int? {
        guard !frames.isEmpty else { return nil }
        return min(frames.count - 1, max(0, Int((t * fps).rounded(.down))))
    }

    /// The analyzed frame at `t` (clip time, seconds).
    public func frame(at t: Double) -> VisionFrame? { index(at: t).map { frames[$0] } }

    /// A joint at `t`, linearly interpolated between neighbouring frames when both saw it.
    public func joint(_ name: String, at t: Double, minConfidence: Double = 0.2) -> VisionPoint? {
        guard !frames.isEmpty else { return nil }
        let x: Double = max(0, min(Double(frames.count - 1), t * fps))
        let i0: Int = Int(x.rounded(.down)), i1: Int = min(frames.count - 1, i0 + 1)
        let f: Double = x - Double(i0)
        guard let a = frames[i0].body[name], a.confidence >= minConfidence else { return nil }
        guard let b = frames[i1].body[name], b.confidence >= minConfidence else { return a }
        return VisionPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f, confidence: min(a.confidence, b.confidence))
    }

    /// Person mask at `t` (white = person), or nil if masks weren't requested.
    public func mask(at t: Double) -> CGImage? {
        guard maskSize.width > 0, let i = index(at: t) else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let img = maskCache[i] { return img }
        let n: Int = maskSize.width * maskSize.height
        guard maskBytes.count >= (i + 1) * n else { return nil }
        let slice = maskBytes.subdata(in: (i * n)..<((i + 1) * n))
        guard let provider = CGDataProvider(data: slice as CFData),
              let img = CGImage(width: maskSize.width, height: maskSize.height, bitsPerComponent: 8, bitsPerPixel: 8,
                                bytesPerRow: maskSize.width, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        maskCache[i] = img
        return img
    }

    /// Body skeleton as joint-name pairs, for drawing.
    public static let bones: [(String, String)] = [
        ("nose", "neck"), ("neck", "leftShoulder"), ("neck", "rightShoulder"),
        ("leftShoulder", "leftElbow"), ("leftElbow", "leftWrist"),
        ("rightShoulder", "rightElbow"), ("rightElbow", "rightWrist"),
        ("neck", "root"), ("root", "leftHip"), ("root", "rightHip"),
        ("leftHip", "leftKnee"), ("leftKnee", "leftAnkle"),
        ("rightHip", "rightKnee"), ("rightKnee", "rightAnkle"),
        ("nose", "leftEye"), ("nose", "rightEye"), ("leftEye", "leftEar"), ("rightEye", "rightEar"),
    ]
    /// Hand skeleton: wrist to each fingertip through its joints.
    public static let handBones: [(String, String)] = {
        var out: [(String, String)] = []
        for finger in ["thumb", "index", "middle", "ring", "little"] {
            let chain = finger == "thumb" ? ["wrist", "thumbCMC", "thumbMP", "thumbIP", "thumbTip"]
                : ["wrist", finger + "MCP", finger + "PIP", finger + "DIP", finger + "Tip"]
            for k in 1..<chain.count { out.append((chain[k - 1], chain[k])) }
        }
        return out
    }()

    // MARK: loading

    private static var memory: [String: VisionTrack] = [:]
    private static let memoryLock = NSLock()

    public static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("swift-render/vision", isDirectory: true)
    }

    /// Analyze `path` (resolved like `VideoClip`) at `fps`, or return the cached result.
    /// Returns an empty track (and warns once) if the file is missing or unreadable.
    public static func load(_ path: String, fps: Double = 30, masks: Bool = true, maskWidth: Int = 320) -> VisionTrack {
        guard let url = AssetPaths.resolve(path) else {
            fputs("[swift-render] VisionTrack: \(path) not found\n", stderr)
            return VisionTrack(fps: fps, frames: [])
        }
        let key = cacheKey(url, fps: fps, masks: masks, maskWidth: maskWidth)
        memoryLock.lock()
        if let hit = memory[key] { memoryLock.unlock(); return hit }
        memoryLock.unlock()
        let track = (try? readCache(key, fps: fps)) ?? {
            do {
                let t = try analyze(url, fps: fps, masks: masks, maskWidth: maskWidth)
                try? writeCache(t, key: key)
                return t
            } catch {
                fputs("[swift-render] VisionTrack: \(error)\n", stderr)
                return VisionTrack(fps: fps, frames: [])
            }
        }()
        memoryLock.lock(); memory[key] = track; memoryLock.unlock()
        return track
    }

    static func cacheKey(_ url: URL, fps: Double, masks: Bool, maskWidth: Int) -> String {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let date = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let raw = "v1|\(url.path)|\(size)|\(date)|\(fps)|\(masks)|\(maskWidth)"
        return SHA256.hash(data: Data(raw.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private struct CacheHeader: Codable { var fps: Double; var frames: [VisionFrame]; var maskWidth: Int; var maskHeight: Int }

    private static func readCache(_ key: String, fps: Double) throws -> VisionTrack {
        let dir = cacheDirectory
        let header = try JSONDecoder().decode(CacheHeader.self, from: Data(contentsOf: dir.appendingPathComponent("\(key).json")))
        let bytes = header.maskWidth > 0 ? try Data(contentsOf: dir.appendingPathComponent("\(key).mask")) : Data()
        return VisionTrack(fps: header.fps, frames: header.frames, maskSize: (header.maskWidth, header.maskHeight), maskBytes: bytes)
    }

    private static func writeCache(_ t: VisionTrack, key: String) throws {
        let dir = cacheDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let header = CacheHeader(fps: t.fps, frames: t.frames, maskWidth: t.maskSize.width, maskHeight: t.maskSize.height)
        try JSONEncoder().encode(header).write(to: dir.appendingPathComponent("\(key).json"))
        if t.maskSize.width > 0 { try t.maskBytes.write(to: dir.appendingPathComponent("\(key).mask")) }
    }

    // MARK: analysis

    static func analyze(_ url: URL, fps: Double, masks: Bool, maskWidth: Int) throws -> VisionTrack {
        let asset = AVURLAsset(url: url)
        let semaphore = DispatchSemaphore(value: 0)
        var videoTrack: AVAssetTrack?
        var transform = CGAffineTransform.identity
        Task.detached {
            videoTrack = try? await asset.loadTracks(withMediaType: .video).first
            if let v = videoTrack { transform = (try? await v.load(.preferredTransform)) ?? .identity }
            semaphore.signal()
        }
        semaphore.wait()
        guard let track = videoTrack else { throw NSError(domain: "VisionTrack", code: 1, userInfo: [NSLocalizedDescriptionKey: "no video track in \(url.lastPathComponent)"]) }
        let orientation = Self.orientation(transform)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()

        let bodyRequest = VNDetectHumanBodyPoseRequest()
        let handRequest = VNDetectHumanHandPoseRequest()
        handRequest.maximumHandCount = 2
        let segRequest = VNGeneratePersonSegmentationRequest()
        segRequest.qualityLevel = .balanced
        segRequest.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let ci = CIContext(options: [.workingColorSpace: NSNull()])

        var frames: [VisionFrame] = []
        var maskBytes = Data()
        var maskW = 0, maskH = 0
        var next = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            // Take this decoded frame for every output slot whose time it covers.
            while Double(next) / fps <= pts + 1e-6 {
                let target = Double(next) / fps
                if pts > target + 1 / fps { frames.append(VisionFrame(time: target)); next += 1; continue }
                let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: orientation, options: [:])
                var requests: [VNRequest] = [bodyRequest, handRequest]
                if masks { requests.append(segRequest) }
                try handler.perform(requests)
                frames.append(VisionFrame(time: target, body: body(bodyRequest), hands: hands(handRequest)))
                if masks {
                    let (bytes, w, h) = maskData(segRequest.results?.first?.pixelBuffer, width: maskWidth, ci: ci)
                    if maskW == 0 { maskW = w; maskH = h }
                    if w == maskW && h == maskH { maskBytes.append(bytes) }
                    else { maskBytes.append(Data(count: maskW * maskH)) }
                }
                next += 1
            }
        }
        return VisionTrack(fps: fps, frames: frames, maskSize: (maskW, maskH), maskBytes: maskBytes)
    }

    static func orientation(_ t: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (t.a, t.b, t.c, t.d) {
        case (0, 1, -1, 0): return .right
        case (0, -1, 1, 0): return .left
        case (-1, 0, 0, -1): return .down
        default: return .up
        }
    }

    static let bodyNames: [VNHumanBodyPoseObservation.JointName: String] = [
        .nose: "nose", .leftEye: "leftEye", .rightEye: "rightEye", .leftEar: "leftEar", .rightEar: "rightEar",
        .neck: "neck", .leftShoulder: "leftShoulder", .rightShoulder: "rightShoulder",
        .leftElbow: "leftElbow", .rightElbow: "rightElbow", .leftWrist: "leftWrist", .rightWrist: "rightWrist",
        .root: "root", .leftHip: "leftHip", .rightHip: "rightHip", .leftKnee: "leftKnee", .rightKnee: "rightKnee",
        .leftAnkle: "leftAnkle", .rightAnkle: "rightAnkle",
    ]
    static let handNames: [VNHumanHandPoseObservation.JointName: String] = [
        .wrist: "wrist",
        .thumbCMC: "thumbCMC", .thumbMP: "thumbMP", .thumbIP: "thumbIP", .thumbTip: "thumbTip",
        .indexMCP: "indexMCP", .indexPIP: "indexPIP", .indexDIP: "indexDIP", .indexTip: "indexTip",
        .middleMCP: "middleMCP", .middlePIP: "middlePIP", .middleDIP: "middleDIP", .middleTip: "middleTip",
        .ringMCP: "ringMCP", .ringPIP: "ringPIP", .ringDIP: "ringDIP", .ringTip: "ringTip",
        .littleMCP: "littleMCP", .littlePIP: "littlePIP", .littleDIP: "littleDIP", .littleTip: "littleTip",
    ]

    static func body(_ request: VNDetectHumanBodyPoseRequest) -> [String: VisionPoint] {
        guard let obs = request.results?.max(by: { $0.confidence < $1.confidence }),
              let points = try? obs.recognizedPoints(.all) else { return [:] }
        var out: [String: VisionPoint] = [:]
        for (joint, p) in points where p.confidence > 0.05 {
            if let name = bodyNames[joint] {
                out[name] = VisionPoint(x: Double(p.location.x), y: 1 - Double(p.location.y), confidence: Double(p.confidence))
            }
        }
        return out
    }

    static func hands(_ request: VNDetectHumanHandPoseRequest) -> [[String: VisionPoint]] {
        (request.results ?? []).compactMap { obs -> [String: VisionPoint]? in
            guard let points = try? obs.recognizedPoints(.all) else { return nil }
            var out: [String: VisionPoint] = [:]
            for (joint, p) in points where p.confidence > 0.05 {
                if let name = handNames[joint] {
                    out[name] = VisionPoint(x: Double(p.location.x), y: 1 - Double(p.location.y), confidence: Double(p.confidence))
                }
            }
            return out.isEmpty ? nil : out
        }
    }

    static func maskData(_ buffer: CVPixelBuffer?, width: Int, ci: CIContext) -> (Data, Int, Int) {
        guard let buffer else { return (Data(), 0, 0) }
        let src = CIImage(cvPixelBuffer: buffer)
        let scale: Double = Double(width) / Double(src.extent.width)
        let w: Int = width, h: Int = max(1, Int((Double(src.extent.height) * scale).rounded()))
        let scaled = src.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        var bytes = Data(count: w * h)
        bytes.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) -> Void in
            guard let base = buf.baseAddress else { return }
            ci.render(scaled, toBitmap: base, rowBytes: w, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                      format: .L8, colorSpace: nil)
        }
        return (bytes, w, h)
    }
}

// MARK: - Drawing

/// Skeleton + hands for one `VisionFrame`, drawn over a frame of `size`.
public struct PoseOverlay: View {
    let frame: VisionFrame?
    let color: Color
    let lineWidth: Double
    let minConfidence: Double

    public init(_ frame: VisionFrame?, color: Color = .white, lineWidth: Double = 6, minConfidence: Double = 0.25) {
        self.frame = frame; self.color = color; self.lineWidth = lineWidth; self.minConfidence = minConfidence
    }

    public var body: some View {
        Canvas { ctx, size in
            guard let frame else { return }
            var path = Path()
            func link(_ joints: [String: VisionPoint], _ bones: [(String, String)]) {
                for (a, b) in bones {
                    guard let p = joints[a], let q = joints[b], p.confidence >= minConfidence, q.confidence >= minConfidence else { continue }
                    path.move(to: p.at(size)); path.addLine(to: q.at(size))
                }
            }
            link(frame.body, VisionTrack.bones)
            for hand in frame.hands { link(hand, VisionTrack.handBones) }
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            for (_, p) in frame.body where p.confidence >= minConfidence {
                let c = p.at(size), r: Double = lineWidth * 1.3
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(color))
            }
        }
    }
}
