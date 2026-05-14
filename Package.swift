// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VoicePOC",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "VoicePOC", targets: ["VoicePOC"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.4"),
    ],
    targets: [
        .executableTarget(
            name: "VoicePOC",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/VoicePOC"
        ),
        .testTarget(
            name: "VoicePOCTests",
            dependencies: ["VoicePOC"],
            path: "Tests/VoicePOCTests"
        ),
    ]
)
