// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SwiftRender",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SwiftRender", targets: ["SwiftRender"]),
        .library(name: "SwiftRenderScenes", targets: ["SwiftRenderScenes"]),
        .executable(name: "swift-render", targets: ["SwiftRenderCLI"]),
    ],
    targets: [
        .target(
            name: "SwiftRender",
            dependencies: [],
            exclude: ["Shaders"],
            resources: [
                .process("Resources"),
            ],
            plugins: ["MetalCompilerPlugin"]
        ),
        .target(
            name: "SwiftRenderScenes",
            dependencies: ["SwiftRender"]
        ),
        .executableTarget(
            name: "SwiftRenderCLI",
            dependencies: ["SwiftRender", "SwiftRenderScenes"],
            plugins: ["SceneRegistryPlugin"]
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
            dependencies: ["SwiftRender", "SwiftRenderScenes"]
        ),
    ]
)
