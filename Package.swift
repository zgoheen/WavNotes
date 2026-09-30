// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WavNotes",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "WavNotes",
            dependencies: ["whisper"]
        ),
        // Prebuilt universal (arm64 + x86_64) whisper.cpp v1.9.2 framework, from
        // https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.2/whisper-v1.9.2-xcframework.zip
        // (sha256 af74fed13ea7f2d5ca2a39d9f58ec177713fafd7cab63aef4e27b79f3ceca80b)
        .binaryTarget(name: "whisper", path: "Frameworks/whisper.xcframework"),
    ]
)
