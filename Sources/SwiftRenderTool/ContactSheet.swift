import AppKit
import Foundation

/// Compose rendered thumbnails into a labelled grid PNG.
func composeContactSheet(cells: [(t: Double, url: URL)], columns: Int, to out: URL) throws {
    guard let first = NSImage(contentsOf: cells[0].url),
          let firstCG = first.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { throw NSError(domain: "ContactSheet", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "could not read first thumbnail"]) }

    let cw = firstCG.width, ch = firstCG.height
    let gap = 4, labelH = 22
    let rows = (cells.count + columns - 1) / columns
    let W = columns * cw + (columns + 1) * gap
    let H = rows * (ch + labelH) + (rows + 1) * gap

    guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw NSError(domain: "ContactSheet", code: 2) }

    ctx.setFillColor(CGColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

    let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.current = nsCtx
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor.white.withAlphaComponent(0.7),
    ]

    for (i, cell) in cells.enumerated() {
        guard let img = NSImage(contentsOf: cell.url),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
        let col = i % columns, row = i / columns
        let x = gap + col * (cw + gap)
        // CG origin is bottom-left; row 0 belongs at the top
        let y = H - (row + 1) * (ch + labelH) - (row + 1) * gap + labelH
        ctx.draw(cg, in: CGRect(x: x, y: y, width: cw, height: ch))
        NSString(format: "%05.2fs", cell.t)
            .draw(at: NSPoint(x: CGFloat(x), y: CGFloat(y - labelH + 3)), withAttributes: attrs)
    }
    NSGraphicsContext.current = nil

    guard let outCG = ctx.makeImage() else { throw NSError(domain: "ContactSheet", code: 3) }
    let rep = NSBitmapImageRep(cgImage: outCG)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "ContactSheet", code: 4)
    }
    try FileManager.default.createDirectory(at: out.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try png.write(to: out)
}
