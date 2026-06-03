// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MLXControl",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MLXControl", path: "Sources/MLXControl")
    ]
)
