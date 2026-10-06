import AVFoundation
import AppKit
import SwiftUI

/// Custom recorder built on AVAssetWriter + ImageRenderer.
/// Replaces StreamUI — fixes audio, output naming, duration drift, and
/// the file-move hack. Frame-deterministic: each frame is rendered fresh
/// from a `(Double) -> View` time function, so internal animations don't
/// rely on display links or timers that may not tick during capture.
@MainActor
public final class Recorder {
    public struct Config {
        public var fps: Int
        /// Layout size in points — what the scene and `RenderContext` see.
        public var size: CGSize
        /// Raster density in pixels per point. Changes resolution, never layout.
        public var scale: CGFloat
        public var codec: AVVideoCodecType
        public var bitrate: Int?
        /// Global grain+vignette pass. CLI --no-postfx sets this false.
        public var postFX: Bool
        private var explicitOutputSize: CGSize?

        public init(
            fps: Int = 60,
            size: CGSize = CGSize(width: 1920, height: 1080),
            scale: CGFloat = 1.0,
            codec: AVVideoCodecType = .h264,
            bitrate: Int? = nil,
            postFX: Bool = true,
            outputSize: CGSize? = nil
        ) {
            self.fps = fps
            self.size = size
            self.scale = scale
            self.codec = codec
            self.bitrate = bitrate
            self.postFX = postFX
            self.explicitOutputSize = outputSize
        }

        /// Encoded pixel size. Defaults to `size × scale` rounded to even (H.264/HEVC
        /// need even dimensions): 1920×1080 at scale 0.5 → 960×540, at scale 2 → 3840×2160.
        /// Set it to encode at another size; frames are then resampled to fit.
        public var outputSize: CGSize {
            get {
                explicitOutputSize ?? CGSize(width: Self.even(size.width * scale), height: Self.even(size.height * scale))
            }
            set { explicitOutputSize = newValue }
        }

        private static func even(_ x: CGFloat) -> CGFloat { max(2, (x / 2).rounded() * 2) }

        public var defaultBitrate: Int {
            if let b = bitrate { return b }
            let pixels = Int(outputSize.width) * Int(outputSize.height)
            switch pixels {
            case 0...921_600: return 6_000_000              // 720p
            case 921_601...2_073_600: return 12_000_000     // 1080p
            case 2_073_601...3_686_400: return 24_000_000   // 1440p
            case 3_686_401...8_294_400: return 35_000_000   // 4K
            default: return 30_000_000
            }
        }
    }

    public let config: Config
    public init(config: Config = Config()) { self.config = config }

    /// Render a SwiftUI view that's a pure function of time `t` (in seconds)
    /// to an MP4 at `outputURL`. Optionally muxes in `audioURL`.
    ///
    /// `duration` is the scene's full length (what `RenderContext` and the scene
    /// see); `startTime`/`endTime` select the span to encode, so a `--range`
    /// render is frame-identical to the same span of a full render.
    /// `progress(frame, total)` is called after each encoded frame.
    public func render<V: View>(
        to outputURL: URL,
        duration: Double,
        startTime: Double = 0,
        endTime: Double? = nil,
        audioURL: URL? = nil,
        postFX: Bool = true,
        progress: (@MainActor (Int, Int) -> Void)? = nil,
        @ViewBuilder content: @escaping @MainActor (Double) -> V
    ) async throws {
        let endTime = min(duration, endTime ?? duration)
        let applyFX = config.postFX && postFX
        // Make sure parent dir exists, remove stale file
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: outputURL)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let width = Int(config.outputSize.width), height = Int(config.outputSize.height)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: config.codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: config.defaultBitrate,
                AVVideoMaxKeyFrameIntervalKey: config.fps * 2,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false

        let pbAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: pbAttrs
        )
        writer.add(videoInput)

        guard writer.startWriting() else {
            throw NSError(domain: "Recorder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "AVAssetWriter failed to start: \(writer.error?.localizedDescription ?? "unknown")"
            ])
        }
        writer.startSession(atSourceTime: .zero)
        let pool = try Self.makePool(width: width, height: height)

        let totalFrames = max(1, Int(((endTime - startTime) * Double(config.fps)).rounded()))
        let timescale: CMTimeScale = CMTimeScale(config.fps)
        let frameDuration = CMTime(value: 1, timescale: timescale)

        for frameIdx in 0..<totalFrames {
            let t = startTime + Double(frameIdx) / Double(config.fps)

            // Drain each frame's autoreleased image memory inside an explicit pool —
            // without it, a long render accumulates every frame's buffers and gets
            // OOM-killed. The pooled CVPixelBuffer is retained and outlives the pool.
            let pixelBuffer: CVPixelBuffer? = autoreleasepool {
                guard let image = makeImage(at: t, duration: duration, postFX: applyFX, content: content) else { return nil }
                var buffer: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                      let buffer, Self.draw(image, into: buffer) else { return nil }
                return buffer
            }
            guard let pixelBuffer else { continue }

            // Wait if input isn't ready
            while !videoInput.isReadyForMoreMediaData {
                try? await Task.sleep(nanoseconds: 200_000)
            }

            let pts = CMTimeMultiply(frameDuration, multiplier: Int32(frameIdx))
            adaptor.append(pixelBuffer, withPresentationTime: pts)
            progress?(frameIdx + 1, totalFrames)
        }

        videoInput.markAsFinished()
        await writer.finishWriting()

        if writer.status == .failed {
            throw writer.error ?? NSError(domain: "Recorder", code: 2)
        }

        // Audio mux: if an audio file is provided, take the just-finished video
        // and mux in the audio track via AVMutableComposition.
        if let audioURL = audioURL, FileManager.default.fileExists(atPath: audioURL.path) {
            try await muxAudio(into: outputURL, audioURL: audioURL, videoDuration: endTime - startTime)
        }
    }

    /// One frame exactly as `render` encodes it, before any resampling to
    /// `outputSize`: `size × scale` pixels, 8-bit sRGB, premultiplied alpha.
    /// Every call uses a fresh ImageRenderer, so no view state carries between frames.
    public func renderImage<V: View>(
        at t: Double,
        postFX: Bool = true,
        duration: Double = 0,
        @ViewBuilder content: @escaping @MainActor (Double) -> V
    ) throws -> CGImage {
        guard let image = makeImage(at: t, duration: duration, postFX: config.postFX && postFX, content: content) else {
            throw NSError(domain: "Recorder", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Frame render produced no image"
            ])
        }
        return image
    }

    /// Render a single frame at time `t` straight to a PNG. The fast path for
    /// checking a scene without producing video — Remotion has Studio, we have this.
    public func renderPNG<V: View>(
        at t: Double,
        to url: URL,
        postFX: Bool = true,
        duration: Double = 0,
        @ViewBuilder content: @escaping @MainActor (Double) -> V
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let image = try renderImage(at: t, postFX: postFX, duration: duration, content: content)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Recorder", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "PNG encode failed"
            ])
        }
        try png.write(to: url)
    }

    private func makeImage<V: View>(at t: Double, duration: Double, postFX: Bool,
                                    content: @escaping @MainActor (Double) -> V) -> CGImage? {
        let root = RenderFrame(size: config.size, fps: config.fps, duration: duration,
                               t: t, postFX: postFX) { content(t) }
        let renderer = ImageRenderer(content: root)
        renderer.scale = config.scale
        return renderer.cgImage
    }

    /// Recycled 32BGRA frame buffers. Deliberately *not* IOSurface-backed (unlike the
    /// writer adaptor's own pool): the encoder converts plain buffers to YUV exactly
    /// as it did the pre-0.9 CIContext buffers, so videos stay bit-identical; IOSurface
    /// sources take another conversion path (≈52 dB PSNR, not identical) for no speedup.
    nonisolated static func makePool(width: Int, height: Int) throws -> CVPixelBufferPool {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool) == kCVReturnSuccess, let pool else {
            throw NSError(domain: "Recorder", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Cannot create a \(width)×\(height) pixel buffer pool"
            ])
        }
        return pool
    }

    /// Copy `image` into a 32BGRA buffer, resampling only if the sizes differ.
    /// `.copy` replaces rather than blends, because pooled buffers hold old frames.
    /// For an sRGB image of the buffer's size this is a byte swizzle — ~0.7 ms at
    /// 1080p vs ~1.2–2 ms through CIContext, byte-identical (RecorderTests). Both
    /// also pay ~1.5 ms the first time they touch an ImageRenderer image, whose
    /// pixels are rasterized lazily.
    nonisolated static func draw(_ image: CGImage, into buffer: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return false }
        ctx.setBlendMode(.copy)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }

    /// Replace the file at `outputURL` with one that has both video and audio tracks.
    private func muxAudio(into outputURL: URL, audioURL: URL, videoDuration: Double) async throws {
        let videoAsset = AVURLAsset(url: outputURL)
        let audioAsset = AVURLAsset(url: audioURL)

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return }

        let vTime = CMTime(seconds: videoDuration, preferredTimescale: CMTimeScale(config.fps))

        let vAssetTracks = try await videoAsset.loadTracks(withMediaType: .video)
        if let v = vAssetTracks.first {
            try videoTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: vTime),
                of: v,
                at: .zero
            )
        }

        let aAssetTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        if let a = aAssetTracks.first {
            let aDuration = try await audioAsset.load(.duration)
            let useDuration = min(aDuration, vTime)
            try audioTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: useDuration),
                of: a,
                at: .zero
            )
        }

        let tempURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("__mux_\(UUID().uuidString).mp4")
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { return }
        exporter.outputURL = tempURL
        exporter.outputFileType = .mp4
        await exporter.export()

        if exporter.status == .completed {
            try? FileManager.default.removeItem(at: outputURL)
            try FileManager.default.moveItem(at: tempURL, to: outputURL)
        } else {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }
}
