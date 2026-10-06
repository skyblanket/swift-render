// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SwiftRender",
    platforms: [.macOS(.v14)],
    products: [
        // The engine: scenes, Timeline, Score, Recorder, LaunchKit.
        .library(name: "SwiftRender", targets: ["SwiftRender"]),
        // The full CLI (render/check/preview/serve/launch/…) as a library, so any
        // package can ship its own `swift-render`-style executable for its scenes.
        .library(name: "SwiftRenderTool", targets: ["SwiftRenderTool"]),
        // Foundation-only shared model: project layout, review comments, host protocol.
        .library(name: "SwiftRenderKit", targets: ["SwiftRenderKit"]),
        .executable(name: "swift-render", targets: ["SwiftRenderCLI"]),
        .executable(name: "swift-render-studio", targets: ["SwiftRenderStudio"]),
        .executable(name: "swift-render-mcp", targets: ["SwiftRenderMCP"]),
        // Apply to your own executable target to auto-register its scenes.
        .plugin(name: "SceneRegistryPlugin", targets: ["SceneRegistryPlugin"]),
    ],
    targets: [
        .target(
            name: "SwiftRenderKit",
            dependencies: []
        ),
        .target(
            name: "SwiftRender",
            dependencies: ["SwiftRenderKit"],
            exclude: ["Shaders"],
            resources: [
                .process("Resources"),
            ],
            plugins: ["MetalCompilerPlugin"]
        ),
        .target(
            name: "SwiftRenderTool",
            dependencies: ["SwiftRender", "SwiftRenderKit"]
        ),
        .executableTarget(
            name: "SwiftRenderCLI",
            dependencies: ["SwiftRender", "SwiftRenderTool"],
            plugins: ["SceneRegistryPlugin"]
        ),
        .executableTarget(
            name: "SwiftRenderStudio",
            dependencies: ["SwiftRenderKit"],
            // SR_STUDIO_PLIST=1 embeds Support/Studio/Info.plist so a bare binary has a bundle id.
            // Opt-in: unsafeFlags must never reach targets that downstream packages build.
            linkerSettings: Context.environment["SR_STUDIO_PLIST"] == "1"
                ? [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                                 "-Xlinker", "__info_plist", "-Xlinker", "Support/Studio/Info.plist"])]
                : []
        ),
        .executableTarget(
            name: "SwiftRenderMCP",
            dependencies: ["SwiftRenderKit"]
        ),
        .plugin(
            name: "MetalCompilerPlugin",
            capability: .buildTool()
        ),
        .plugin(
            name: "SceneRegistryPlugin",
            capability: .buildTool()
        ),
        .testTarget(
            name: "SwiftRenderTests",
            dependencies: ["SwiftRender", "SwiftRenderKit", "SwiftRenderTool"]
        ),
        .testTarget(
            name: "SwiftRenderStudioTests",
            dependencies: ["SwiftRenderStudio", "SwiftRenderKit"]
        ),
    ]
)
