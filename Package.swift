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
            resources: [
                .process("Resources"),
                .process("Shaders"),
            ]
        ),
        .executableTarget(
            name: "SwiftRenderCLI",
            dependencies: ["SwiftRender"]
        ),
        .testTarget(
            name: "SwiftRenderTests",
            dependencies: ["SwiftRender"]
        ),
    ]
)
