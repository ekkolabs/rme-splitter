// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RMESplitter",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "SplitterCore"),
        .executableTarget(name: "RMESplitter", dependencies: ["SplitterCore"]),
        .testTarget(name: "SplitterCoreTests", dependencies: ["SplitterCore"]),
    ],
    swiftLanguageModes: [.v5]
)
