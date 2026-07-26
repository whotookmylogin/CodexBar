// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexBar",
    platforms: [
        .macOS(.v13),
    ],
    targets: [
        .executableTarget(
            name: "CodexBar",
            path: "Sources/CodexBar"),
        .testTarget(
            name: "CodexBarTests",
            dependencies: ["CodexBar"],
            path: "Tests"),
    ])
