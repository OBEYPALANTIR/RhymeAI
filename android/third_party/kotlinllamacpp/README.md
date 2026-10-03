# llamaCpp Native Library

This module contains the Android bindings and the core C++ inference engine based on `llama.cpp`.

## Native Codebase Synchronization

`UPSTREAM.md` records the source repository, pinned revision, imported path, and local patches for this vendored module. Update the module by importing the same upstream path at a reviewed revision, preserving the Android patches documented there, and recording the new revision before committing the generated diff.

## Directory Structure
- `src/main/cpp/lib`: Core `llama.cpp` and wrapper files (Synced).
- `src/main/cpp/jni.cpp`: The JNI bridge connecting Kotlin to the C++ core.
- `src/main/cpp/CMakeLists.txt`: Build configuration for Android NDK.

## Architecture Support
The library is optimized for the following 64-bit architectures:
- **`arm64-v8a`**: Includes specialized targets for `dotprod` and `i8mm` (Int8 Matmul) acceleration.
- **`x86_64`**: Full support for modern desktop-class mobile processors.

## Custom Patches
If you modify the core `llama.cpp` behavior, record the local patch in `UPSTREAM.md` so it can be preserved during the next reviewed import.
