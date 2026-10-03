# kotlinllamacpp provenance

- Upstream: https://github.com/ljcamargo/kotlinllamacpp
- Pinned source revision: `c292c068bdd258203dd41fc6d0f08578eddd59f3`
- Published source reference: `io.github.ljcamargo:llamacpp-kotlin:0.4.0`
- Imported path: upstream `llamaCpp/`
- Shipped ABIs: `arm64-v8a`, `x86_64`
- Local build: Android Gradle Plugin 8.9.1, Kotlin 2.3.20, CMake 3.22.1, NDK 27.0.12077973

The imported `llamaCpp/` tree at the pinned revision is byte-identical to
revision `7bfeb37cca27e3d1daed3da8ef2c2fdf4e7ff81b`, whose project metadata declares
version 0.4.0. The pinned revision includes the upstream MIT license retained in
`LICENSE`.

The local patch removes completion parameters, prompts, output text, stop words,
and prompt or generated token identifiers from Kotlin and native logs. Runtime
state, counts, timings, failures, and model diagnostics remain available without
recording writing content.

File descriptors passed to synchronous native entry points remain owned by the
Kotlin caller. The native loaders duplicate descriptors internally while opening
model and media data, and callers keep each descriptor open until the matching
entry point returns.
