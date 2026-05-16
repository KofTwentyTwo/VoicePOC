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
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git", from: "1.20.0"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", .upToNextMajor(from: "0.18.0")),
    ],
    targets: [
        .executableTarget(
            name: "VoicePOC",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/VoicePOC"
        ),
        .testTarget(
            name: "VoicePOCTests",
            dependencies: ["VoicePOC"],
            path: "Tests/VoicePOCTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
