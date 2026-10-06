import CoreText
import Foundation
import SwiftUI

// MARK: - Font registration

@MainActor
public func registerBundledFonts() {
    let bundle = Bundle.module
    let names = ["Inter", "InterVariable"]
    for name in names {
        for ext in ["ttc", "ttf"] {
            if let url = bundle.url(forResource: name, withExtension: ext) {
                var error: Unmanaged<CFError>?
                if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                    if let e = error?.takeRetainedValue() {
                        let desc = CFErrorCopyDescription(e) as String
                        if !desc.contains("already") {
                            fputs("font register fail \(name).\(ext): \(desc)\n", stderr)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Shader freshness


// MARK: - Shader library for scenes outside this module

public extension ShaderLibrary {
    /// swift-render's compiled shaders. Inside the SwiftRender module this is
    /// `.bundle(.module)`; scenes in your own package must use this instead,
    /// because their `.module` is their own bundle.
    static var swiftRender: ShaderLibrary { .bundle(.module) }
}
