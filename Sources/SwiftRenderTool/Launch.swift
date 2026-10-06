import Foundation
import SwiftRender
import SwiftRenderKit

// MARK: - swift-render launch / init
//
// `launch <path>`: scan a Swift codebase and render an Apple-style launch film.
// `init`: scaffold a Launch/ package (scenes + CLI) inside a Swift codebase.
// STUB — implemented by the LaunchKit work.

@MainActor
func runLaunch(_ args: [String]) async throws {
    fputs("[swift-render] launch: not implemented yet\n", stderr)
    exit(2)
}

@MainActor
func runInit(_ args: [String]) throws {
    fputs("[swift-render] init: not implemented yet\n", stderr)
    exit(2)
}

/// Template scenes every project gets (merged under the project's own registry).
@MainActor
func builtinSceneRunners() -> [String: SceneRunner] {
    [:]
}
