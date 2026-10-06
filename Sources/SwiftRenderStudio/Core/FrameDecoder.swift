import CoreGraphics
import Foundation
import ImageIO
import SwiftRenderKit

// MARK: - Frame decoding
//
// jpeg/png arrive base64 in `HostFrame.data`; bgra8 arrives as a raw payload after
// the header line and wraps into a CGImage without copying or decoding.

enum FrameDecoderError: Error, Equatable {
    case badBase64
    case undecodable(String)
    case payloadSize(expected: Int, got: Int)
    case unknownFormat(String)
}

enum FrameDecoder {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func image(from f: HostFrame, payload: Data?) throws -> CGImage {
        switch f.format {
        case FrameFormat.bgra8.rawValue:
            let expected = f.width * f.height * 4
            guard let payload, payload.count == expected else {
                throw FrameDecoderError.payloadSize(expected: expected, got: payload?.count ?? 0)
            }
            return try bgra8(payload, width: f.width, height: f.height)
        case FrameFormat.jpeg.rawValue, FrameFormat.png.rawValue:
            // Binary framing may also carry encoded bytes; prefer the payload when present.
            let bytes: Data
            if let payload, f.data.isEmpty { bytes = payload }
            else {
                guard let d = Data(base64Encoded: f.data) else { throw FrameDecoderError.badBase64 }
                bytes = d
            }
            return try encoded(bytes)
        default:
            throw FrameDecoderError.unknownFormat(f.format)
        }
    }

    static func decode(_ f: HostFrame, payload: Data?, surface: FrameSurface? = nil, fps: Int) throws -> DecodedFrame {
        if let surface, f.format == FrameFormat.bgra8.rawValue {
            guard let img = surface.makeImage() else { throw FrameDecoderError.undecodable("surface \(f.width)x\(f.height)") }
            return DecodedFrame(t: f.t, index: f.index ?? frameIndex(f.t, fps: fps), width: img.width, height: img.height,
                                image: img, ms: f.ms, format: .bgra8, surface: surface)
        }
        let img = try image(from: f, payload: payload)
        return DecodedFrame(t: f.t, index: f.index ?? frameIndex(f.t, fps: fps), width: img.width, height: img.height,
                            image: img, ms: f.ms, format: FrameFormat(rawValue: f.format) ?? .jpeg)
    }

    /// Premultiplied-first, little-endian 32-bit (`BGRA` in memory), rowBytes = width*4.
    static func bgra8(_ data: Data, width: Int, height: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: data as CFData),
              let img = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: width * 4, space: sRGB,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                         | CGBitmapInfo.byteOrder32Little.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw FrameDecoderError.undecodable("bgra8 \(width)x\(height)") }
        return img
    }

    static func encoded(_ data: Data) throws -> CGImage {
        let opts = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, opts)
        else { throw FrameDecoderError.undecodable("image data (\(data.count) bytes)") }
        return img
    }

    /// Inverse of `bgra8(_:)` — used by FakeHost and tests to produce wire payloads.
    static func bgra8Bytes(_ image: CGImage) -> Data? {
        let w = image.width, h = image.height
        var data = Data(count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: sRGB,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? data : nil
    }

    /// JPEG/PNG encode (FakeHost wire path, attachments).
    static func encode(_ image: CGImage, format: FrameFormat, quality: Double = 0.8) -> Data? {
        let type = (format == .png ? "public.png" : "public.jpeg") as CFString
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return out as Data
    }
}
