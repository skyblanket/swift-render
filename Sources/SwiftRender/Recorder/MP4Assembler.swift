import AVFoundation
import Foundation

/// Joins already-encoded video segments end to end and muxes an audio file,
/// **without re-encoding the video**: H.264 samples are copied and retimed, only
/// the audio is encoded (AAC 256 kbps). Used for the recorder's audio mux and to
/// stitch `--jobs` chunks back into one file.
public enum MP4Assembler {
    public enum Failure: Error, CustomStringConvertible {
        case noVideo(URL), writer(String)
        public var description: String {
            switch self {
            case .noVideo(let u): return "no video track in \(u.lastPathComponent)"
            case .writer(let why): return "MP4Assembler: \(why)"
            }
        }
    }

    /// Write `segments` (in order) plus optional `audio` (trimmed to the video) to `output`.
    public static func assemble(video segments: [URL], audio: URL?, to output: URL) async throws {
        precondition(!segments.isEmpty)
        // Video readers, one per segment, with each segment's start offset.
        var parts: [(AVAssetReader, AVAssetReaderTrackOutput, CMTime)] = []
        var cursor = CMTime.zero
        var hint: CMFormatDescription?
        for url in segments {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo(url) }
            if hint == nil { hint = try await track.load(.formatDescriptions).first }
            let reader = try AVAssetReader(asset: asset)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            out.alwaysCopiesSampleData = false
            reader.add(out)
            parts.append((reader, out, cursor))
            cursor = cursor + (try await asset.load(.duration))
        }
        let total = cursor

        var audioReader: AVAssetReader?
        var audioOut: AVAssetReaderTrackOutput?
        if let audio {
            let asset = AVURLAsset(url: audio)
            if let track = try await asset.loadTracks(withMediaType: .audio).first {
                let reader = try AVAssetReader(asset: asset)
                let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ])
                reader.add(out)
                audioReader = reader; audioOut = out
            }
        }

        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = output.deletingLastPathComponent().appendingPathComponent(".__assemble_\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let writer = try AVAssetWriter(outputURL: tmp, fileType: .mp4)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
        vIn.expectsMediaDataInRealTime = false
        writer.add(vIn)
        var aIn: AVAssetWriterInput?
        if audioOut != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            aIn = input
        }
        guard writer.startWriting() else { throw Failure.writer(writer.error?.localizedDescription ?? "start failed") }
        writer.startSession(atSourceTime: .zero)

        var part = 0
        var shift: CMTime? = nil       // segment start − its first frame's own timestamp
        if let first = parts.first { first.0.startReading() }
        audioReader?.startReading()
        var videoDone = false, audioDone = aIn == nil

        // Encoders with B-frames place frame 0 a few ticks into the media timeline (edit
        // list). Anchor each segment on its first sample so seams land exactly on `start`.
        func nextVideo() -> CMSampleBuffer? {
            while part < parts.count {
                let (_, out, start) = parts[part]
                if let sb = out.copyNextSampleBuffer() {
                    if CMSampleBufferGetNumSamples(sb) == 0 { continue }   // reader marker buffers
                    if shift == nil { shift = start - CMSampleBufferGetPresentationTimeStamp(sb) }
                    return shift == .zero ? sb : retimed(sb, by: shift!)
                }
                part += 1
                shift = nil
                if part < parts.count { parts[part].0.startReading() }
            }
            return nil
        }

        // Interleave: append whichever input is ready, so neither starves the other.
        while !(videoDone && audioDone) {
            var progressed = false
            if !videoDone && vIn.isReadyForMoreMediaData {
                if let sb = nextVideo() { vIn.append(sb) } else { vIn.markAsFinished(); videoDone = true }
                progressed = true
            }
            if !audioDone, let aIn, aIn.isReadyForMoreMediaData {
                if let sb = audioOut?.copyNextSampleBuffer(), CMSampleBufferGetPresentationTimeStamp(sb) < total {
                    aIn.append(sb)
                } else { aIn.markAsFinished(); audioDone = true }
                progressed = true
            }
            if writer.status == .failed { throw Failure.writer(writer.error?.localizedDescription ?? "write failed") }
            if !progressed { try await Task.sleep(nanoseconds: 300_000) }
        }
        writer.endSession(atSourceTime: total)
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure.writer(writer.error?.localizedDescription ?? "finish failed") }
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: tmp, to: output)
    }

    static func retimed(_ sb: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in timing.indices {
            if timing[i].presentationTimeStamp.isValid { timing[i].presentationTimeStamp = timing[i].presentationTimeStamp + offset }
            if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = timing[i].decodeTimeStamp + offset }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sb,
                                              sampleTimingEntryCount: count, sampleTimingArray: &timing,
                                              sampleBufferOut: &out)
        return out ?? sb
    }
}
