# Archived llama.cpp iOS framework

The active mobile target links the checksum-pinned b9949 package in
`../LlamaFramework/Package.swift`. This b9637 subset is retained historical
source material and is not linked into the runtime composition.

`llama.xcframework` is the device and simulator subset of the official llama.cpp Apple XCFramework from release `b9637` (commit `aedb2a5e9ca3d4064148bbb919e0ddc0c1b70ab3`).

- Upstream: https://github.com/ggml-org/llama.cpp
- Release asset: https://github.com/ggml-org/llama.cpp/releases/download/b9637/llama-b9637-xcframework.zip
- Upstream archive SHA-256: `46c7dad871f804d82399ddcfeb54d23b6469888801fc35124d7e33e543a9bef7`
- Included slices: `ios-arm64` and `ios-arm64_x86_64-simulator`
- License: MIT; see `LICENSE.llama.cpp`

The macOS and visionOS slices are intentionally omitted because this target only supports iPhone and iPhone Simulator. Recreate the subset with `xcodebuild -create-xcframework` when updating the pinned upstream release.
