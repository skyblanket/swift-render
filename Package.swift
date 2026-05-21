// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SwiftRender",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "swift-render", targets: ["SwiftRender"]),
    ],
    targets: [
        .executableTarget(
            name: "SwiftRender",
            dependencies: [],
            resources: [
                .process("Resources"),
                .process("Shaders"),
            ]
        ),
    ]
)
