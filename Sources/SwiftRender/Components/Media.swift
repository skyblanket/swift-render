import AVFoundation
import AppKit
import SwiftUI

/// Frame-accurate access to video and image files for scenes.
///
/// Video frames are decoded with zero time tolerance, so the frame shown at `t`
/// is the same on every render. Paths resolve like samples (cwd, assets/, root).
public enum MediaLibrary {
    private static let sources = LockedCache<String, VideoSource?>()
    private static let images = LockedCache<String, CGImage?>()

    static func source(_ path: String) -> VideoSource? {
        // Versioned by the resolved file and its stamp, so an edited clip is re-opened.
        let resolved = AssetPaths.resolve(path)
        return sources.value(path, version: resolved.map { $0.path + "|" + FileStamp.of($0.path) } ?? "missing") {
            guard let url = resolved else {
                fputs("[swift-render] WARN: video not found: \(path)\n", stderr)
                return nil
            }
            return VideoSource(url: url)
        }
    }

    /// Duration of a video file in seconds (0 if unreadable).
    public static func duration(_ path: String) -> Double { source(path)?.duration ?? 0 }

    /// The video frame at `seconds` (clamped to the clip).
    public static func frame(_ path: String, at seconds: Double) -> CGImage? {
        source(path)?.frame(at: seconds)
    }

    /// A still image from disk (png, jpg, heic, webp, …).
    public static func image(_ path: String) -> CGImage? {
        let resolved = AssetPaths.resolve(path)
        return images.value(path, version: resolved.map { $0.path + "|" + FileStamp.of($0.path) } ?? "missing") {
            guard let url = resolved,
                  let ns = NSImage(contentsOf: url),
                  let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else {
                fputs("[swift-render] WARN: image not found or unreadable: \(path)\n", stderr)
                return nil
            }
            return cg
        }
    }
}

final class VideoSource: @unchecked Sendable {
    let generator: AVAssetImageGenerator
    let duration: Double
    private let frames = LockedCache<Int64, CGImage?>(limit: 24)

    init(url: URL) {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        generator = gen
        let box = ResultBox<Double>()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = (try? await asset.load(.duration)).map { $0.seconds } ?? 0
            sem.signal()
        }
        sem.wait()
        duration = box.value ?? 0
    }

    func frame(at seconds: Double) -> CGImage? {
        let s = max(0, min(seconds, max(0, duration - 0.001)))
        let key = Int64((s * 6000).rounded())
        return frames.value(key) {
            let box = ResultBox<CGImage>()
            let sem = DispatchSemaphore(value: 0)
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(value: key, timescale: 6000))]) { _, image, _, _, _ in
                box.value = image
                sem.signal()
            }
            sem.wait()
            return box.value
        }
    }
}

/// A video file as a view, driven by scene time.
///
///     VideoClip("clips/demo.mp4", at: l)                 // local clip time
///     VideoClip("clips/demo.mp4", at: l, rate: 0.5, loop: true, contentMode: .fit)
///
/// Pair it with `sample("clips/demo.mp4", at: clipStart)` in the Score for its sound.
public struct VideoClip: View {
    let path: String
    let time: Double
    var contentMode: ContentMode

    /// `t` is seconds into the clip (before `rate`/`offset`); past the end it
    /// holds the last frame unless `loop` is set.
    public init(_ path: String, at t: Double, rate: Double = 1, offset: Double = 0,
                loop: Bool = false, contentMode: ContentMode = .fill) {
        self.path = path
        var local = max(0, t) * rate + offset
        if loop {
            let d = MediaLibrary.duration(path)
            if d > 0 { local = local.truncatingRemainder(dividingBy: d) }
        }
        self.time = local
        self.contentMode = contentMode
    }

    public var body: some View {
        if let cg = MediaLibrary.frame(path, at: time) {
            Image(decorative: cg, scale: 1).resizable().aspectRatio(contentMode: contentMode)
        } else {
            Color.black
        }
    }
}

/// A still image file as a view (`bundledImage` is for package resources).
public struct ImageClip: View {
    let path: String
    var contentMode: ContentMode

    public init(_ path: String, contentMode: ContentMode = .fit) {
        self.path = path; self.contentMode = contentMode
    }

    public var body: some View {
        if let cg = MediaLibrary.image(path) {
            Image(decorative: cg, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: contentMode)
        } else {
            Color.clear
        }
    }
}
