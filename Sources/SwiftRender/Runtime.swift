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

