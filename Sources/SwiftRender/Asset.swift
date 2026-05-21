import AppKit
import SwiftUI

/// Load a PNG/JPEG resource bundled via SPM `.process("Resources")`.
/// Returns a SwiftUI Image, falling back to a placeholder if missing.
public func bundledImage(_ name: String, ext: String = "png") -> Image {
    if let url = Bundle.module.url(forResource: name, withExtension: ext),
       let nsImage = NSImage(contentsOf: url) {
        return Image(nsImage: nsImage)
    }
    fputs("[swift-render] WARN: missing asset \(name).\(ext) in Bundle.module\n", stderr)
    return Image(systemName: "questionmark.square")
}
