// swift-tools-version:6.0
import PackageDescription

// VoicePOC is built as a macOS .app bundle (see project.yml + xcodegen).
// The Swift package here exposes VoicePOC as a *library* that the .app target
// consumes, and provides the test target. SwiftUI HUD code lives inside the
// library; only the .app target actually links SwiftUICore at bundle build
// time (SwiftPM CLI executables can't link SwiftUICore).
let package = Package(
    name: "VoicePOCKit",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "VoicePOCKit", targets: ["VoicePOCKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.4"),
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git", from: "1.20.0"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", .upToNextMajor(from: "0.18.0")),
    ],
    targets: [
        .target(
            name: "VoicePOCKit",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/VoicePOC"
        ),
        .testTarget(
            name: "VoicePOCTests",
            dependencies: ["VoicePOCKit"],
            path: "Tests/VoicePOCTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
