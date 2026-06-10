// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SwiftRender",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SwiftRender", targets: ["SwiftRender"]),
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
        .executableTarget(
            name: "SwiftRenderCLI",
            dependencies: ["SwiftRender"]
        ),
        .plugin(
            name: "MetalCompilerPlugin",
            capability: .buildTool()
        ),
        .testTarget(
            name: "SwiftRenderTests",
            dependencies: ["SwiftRender"]
        ),
    ]
)
