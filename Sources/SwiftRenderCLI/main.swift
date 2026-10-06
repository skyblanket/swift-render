import SwiftRenderTool

// The swift-render CLI for this repo's scenes. `generatedSceneRunners` is
// written at build time by SceneRegistryPlugin.
await SwiftRenderTool.main(scenes: generatedSceneRunners)
