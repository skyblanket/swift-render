import CoreGraphics
import Foundation
import ImageIO

// MARK: - Review frames
//
// Small image helpers for the review loop: draw a comment's region box on a
// rendered frame and cap its width before it goes to an agent (MCP image
// content) or a person (`swift-render review frame`). CoreGraphics + ImageIO
// only, so Studio, the CLI and the MCP server can all use them.

/// Errors reading or encoding review frames.
public enum ReviewImageError: Error, CustomStringConvertible {
    case unreadable(String)
    case encode(String)
    /// Human-readable message.
    public var description: String {
        switch self {
        case .unreadable(let what): return "cannot read image \(what)"
        case .encode(let what): return "cannot encode PNG \(what)"
        }
    }
}

/// Image helpers for review frames: outline a region, cap the width, write PNG.
public enum ReviewImage {
    /// Box colour: a saturated pink that reads on both dark and bright frames.
    public static let boxColor = (r: 1.0, g: 0.18, b: 0.47)

    /// Loads the first image in a file.
    public static func load(_ url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ReviewImageError.unreadable(url.path)
        }
        return img
    }

    /// Loads the first image from encoded bytes.
    public static func load(data: Data) throws -> CGImage {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ReviewImageError.unreadable("(\(data.count) bytes)")
        }
        return img
    }

    /// Downscales so the width is at most `maxWidth` (aspect kept). Never upscales.
    public static func scaled(_ image: CGImage, maxWidth: Int) -> CGImage {
        guard maxWidth > 0, image.width > maxWidth else { return image }
        let w = maxWidth
        let h = max(1, Int((Double(image.height) * Double(w) / Double(image.width)).rounded()))
        guard let ctx = context(width: w, height: h) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    /// The frame with `region` outlined. The stroke sits just outside the region so
    /// the pixels being discussed stay untouched; a dark under-stroke keeps it legible.
    public static func annotated(_ image: CGImage, region: ReviewRegion?) -> CGImage {
        guard let region, let ctx = context(width: image.width, height: image.height) else { return image }
        let W = image.width, H = image.height
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))

        let line = max(2.0, (Double(max(W, H)) / 480).rounded())
        let px = region.pixelRect(width: W, height: H)
        // CG's origin is bottom-left; regions are top-left.
        let r = CGRect(x: px.minX, y: Double(H) - px.maxY, width: px.width, height: px.height)
            .insetBy(dx: -line / 2, dy: -line / 2)
        ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.55))
        ctx.setLineWidth(line + 2)
        ctx.stroke(r)
        ctx.setStrokeColor(CGColor(srgbRed: boxColor.r, green: boxColor.g, blue: boxColor.b, alpha: 1))
        ctx.setLineWidth(line)
        ctx.stroke(r)
        return ctx.makeImage() ?? image
    }

    /// Encodes an image as PNG.
    public static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else {
            throw ReviewImageError.encode("(no destination)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ReviewImageError.encode("(finalize failed)") }
        return data as Data
    }

    /// Writes an image as PNG, creating parent directories.
    public static func write(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png(image).write(to: url, options: .atomic)
    }

    /// Load → outline `region` → cap width → PNG bytes. What agents are shown.
    public static func prepare(_ url: URL, region: ReviewRegion? = nil, maxWidth: Int? = nil) throws -> Data {
        var img = try load(url)
        // Box first at full resolution so the stroke weight is relative to the canvas.
        img = annotated(img, region: region)
        if let maxWidth { img = scaled(img, maxWidth: maxWidth) }
        return try png(img)
    }

    private static func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}
