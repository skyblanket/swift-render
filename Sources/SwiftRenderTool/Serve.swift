import Foundation
import SwiftRender
import SwiftRenderKit

// MARK: - swift-render serve
//
// Render host for Studio: JSON Lines over stdio, see SwiftRenderKit/HostProtocol.swift.
// STUB — implemented by the Studio/host work.

@MainActor
func runServe(_ args: [String]) async throws {
    fputs("[swift-render] serve: not implemented yet\n", stderr)
    exit(2)
}
