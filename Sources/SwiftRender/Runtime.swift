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

/// default.metallib is pre-compiled and checked in; editing a .metal file does
/// nothing until it is rebuilt. Catch that silently-stale state loudly.
public func checkShaderFreshness() {
    let bundle = Bundle.module
    let fm = FileManager.default
    guard let lib = bundle.url(forResource: "default", withExtension: "metallib"),
          let libDate = (try? fm.attributesOfItem(atPath: lib.path))?[.modificationDate] as? Date
    else { return }
    let stale = (bundle.urls(forResourcesWithExtension: "metal", subdirectory: nil) ?? [])
        .filter { url in
            ((try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)
                .map { $0 > libDate } ?? false
        }
        .map(\.lastPathComponent)
    if !stale.isEmpty {
        fputs("""
        !!! ────────────────────────────────────────────────────────────────
        !!! STALE SHADERS: \(stale.joined(separator: ", "))
        !!!   are newer than default.metallib — your .metal edits are NOT live.
        !!!   Fix:  tools/build_shaders.sh && swift build
        !!! ────────────────────────────────────────────────────────────────

        """, stderr)
    }
}

