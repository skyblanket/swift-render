import AVFoundation
import AppKit
import CoreImage
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
        public var size: CGSize
        public var scale: CGFloat
        public var codec: AVVideoCodecType
        public var bitrate: Int?

        public init(
            fps: Int = 60,
            size: CGSize = CGSize(width: 1920, height: 1080),
            scale: CGFloat = 1.0,
            codec: AVVideoCodecType = .h264,
            bitrate: Int? = nil
        ) {
            self.fps = fps
            self.size = size
            self.scale = scale
            self.codec = codec
            self.bitrate = bitrate
        }

        public var defaultBitrate: Int {
            if let b = bitrate { return b }
            let pixels = Int(size.width) * Int(size.height)
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
    public func render<V: View>(
        to outputURL: URL,
        duration: Double,
        startTime: Double = 0,
        audioURL: URL? = nil,
        @ViewBuilder content: @escaping @MainActor (Double) -> V
    ) async throws {
        // Make sure parent dir exists, remove stale file
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: outputURL)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: config.codec,
            AVVideoWidthKey: Int(config.size.width),
            AVVideoHeightKey: Int(config.size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: config.defaultBitrate,
                AVVideoMaxKeyFrameIntervalKey: config.fps * 2,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false

        let pbAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(config.size.width),
            kCVPixelBufferHeightKey as String: Int(config.size.height),
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

        let totalFrames = max(1, Int(((duration - startTime) * Double(config.fps)).rounded()))
        let timescale: CMTimeScale = CMTimeScale(config.fps)
        let frameDuration = CMTime(value: 1, timescale: timescale)

        let imageContext = CIContext()
        let scaleCG = config.scale

        for frameIdx in 0..<totalFrames {
            let t = startTime + Double(frameIdx) / Double(config.fps)

            // Build a fresh view for this frame; apply PostFX wrapper at the top.
            let rootView = ZStack {
                content(t)
            }
            .frame(width: config.size.width, height: config.size.height)
            .modifier(PostFX(time: t))

            let renderer = ImageRenderer(content: rootView)
            renderer.scale = scaleCG

            guard let nsImage = renderer.nsImage,
                  let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { continue }

            guard let pixelBuffer = makePixelBuffer(from: cgImage, size: config.size, ciContext: imageContext) else { continue }

            // Wait if input isn't ready
            while !videoInput.isReadyForMoreMediaData {
                try? await Task.sleep(nanoseconds: 200_000)
            }

            let pts = CMTimeMultiply(frameDuration, multiplier: Int32(frameIdx))
            adaptor.append(pixelBuffer, withPresentationTime: pts)
        }

        videoInput.markAsFinished()
        await writer.finishWriting()

        if writer.status == .failed {
            throw writer.error ?? NSError(domain: "Recorder", code: 2)
        }

        // Audio mux: if an audio file is provided, take the just-finished video
        // and mux in the audio track via AVMutableComposition.
        if let audioURL = audioURL, FileManager.default.fileExists(atPath: audioURL.path) {
            try await muxAudio(into: outputURL, audioURL: audioURL, videoDuration: duration)
        }
    }

    /// Render a single frame at time `t` straight to a PNG. The fast path for
    /// checking a scene without producing video — Remotion has Studio, we have this.
    public func renderPNG<V: View>(
        at t: Double,
        to url: URL,
        @ViewBuilder content: @escaping @MainActor (Double) -> V
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let rootView = ZStack { content(t) }
            .frame(width: config.size.width, height: config.size.height)
            .modifier(PostFX(time: t))
        let renderer = ImageRenderer(content: rootView)
        renderer.scale = config.scale
        guard let nsImage = renderer.nsImage,
              let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            throw NSError(domain: "Recorder", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Frame render produced no image"
            ])
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Recorder", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "PNG encode failed"
            ])
        }
        try png.write(to: url)
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

    private func makePixelBuffer(from cgImage: CGImage, size: CGSize, ciContext: CIContext) -> CVPixelBuffer? {
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ] as CFDictionary

        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width), Int(size.height),
            kCVPixelFormatType_32BGRA,
            attrs,
            &pb
        )
        guard status == kCVReturnSuccess, let buffer = pb else { return nil }

        let ci = CIImage(cgImage: cgImage)
        // Scale CIImage to match pixel-buffer size (handles displayScale != 1).
        let scaledCI = ci.transformed(by: CGAffineTransform(
            scaleX: size.width / ci.extent.width,
            y: size.height / ci.extent.height
        ))
        ciContext.render(scaledCI, to: buffer)
        return buffer
    }
}
