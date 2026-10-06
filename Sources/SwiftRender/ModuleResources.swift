import Foundation
import SwiftUI

/// Public handles on this module's bundle, for code in other targets (the demo
/// scenes, your own package) — `.module` always means the *calling* target.
public extension Bundle {
    /// SwiftRender's resource bundle: fonts, images, the compiled metallib.
    static var swiftRender: Bundle { .module }
}

public extension ShaderLibrary {
    /// Every shader in Sources/SwiftRender/Shaders:
    /// `Rectangle().colorEffect(ShaderLibrary.swiftRender.galaxy(.float2(w, h), .float(t)))`.
    static var swiftRender: ShaderLibrary { .bundle(.module) }
}
