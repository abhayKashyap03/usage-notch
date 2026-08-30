// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UsageNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "UsageNotch",
            path: "Sources/UsageNotch"
        ),
        .testTarget(
            name: "UsageNotchTests",
            dependencies: ["UsageNotch"],
            path: "Tests/UsageNotchTests"
        )
    ]
)
