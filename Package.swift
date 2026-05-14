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
        // populated in Task 2
    ],
    targets: [
        .executableTarget(
            name: "VoicePOC",
            path: "Sources/VoicePOC"
        ),
        .testTarget(
            name: "VoicePOCTests",
            dependencies: ["VoicePOC"],
            path: "Tests/VoicePOCTests"
        ),
    ]
)
