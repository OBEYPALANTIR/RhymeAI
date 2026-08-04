// swift-tools-version: 5.9
// Wraps the prebuilt llama.xcframework published on llama.cpp GitHub releases.
// llama.cpp removed source-level SPM support (PR #11996); binary distribution
// is the supported way to consume it from Swift. Pinned to tag b9949.
import PackageDescription

let package = Package(
    name: "LlamaFramework",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "llama", targets: ["llama"])
    ],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b9949/llama-b9949-xcframework.zip",
            checksum: "7683b72e2036cf5e494cd3389547677c3614a16c073ae9c8611ae8df5b28b267"
        )
    ]
)
