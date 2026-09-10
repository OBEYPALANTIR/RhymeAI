# llamaCpp Native Library

This module contains the Android bindings and the core C++ inference engine based on `llama.cpp`.

## Native Codebase Synchronization

To keep the native inference engine up-to-date with the latest developments in the ecosystem, this project uses a synchronization script that pulls code from a modernized fork maintained by the community (`cui-llama.rn`).

### Prerequisites
- `git`
- `bash` (or Git Bash on Windows)

### How to Sync
Run the following script from the root of the project:

```bash
./scripts/sync_llamacpp.sh
```

### What the Script Does
1.  **Clones the Upstream**: Fetches the latest stable modernized wrappers and core files.
2.  **Symbol Prefixing**: Automatically applies `LM_` and `lm_` prefixes to `ggml` and `llama` symbols. This is crucial to avoid naming collisions if your app uses other native libraries that might bundle a different version of `ggml` (like `whisper.cpp`).
3.  **Modern Layout**: Organizes the files into the modular directory structure required by the latest `llama.cpp` builds (subdirectories for `common`, `models`, `tools`, etc.).
4.  **Patches**: Applies specialized Android fixes, such as the File Descriptor (FD) loading mechanism required for modern Android security.

## Directory Structure
- `src/main/cpp/lib`: Core `llama.cpp` and wrapper files (Synced).
- `src/main/cpp/jni.cpp`: The JNI bridge connecting Kotlin to the C++ core.
- `src/main/cpp/CMakeLists.txt`: Build configuration for Android NDK.

## Architecture Support
The library is optimized for the following 64-bit architectures:
- **`arm64-v8a`**: Includes specialized targets for `dotprod` and `i8mm` (Int8 Matmul) acceleration.
- **`x86_64`**: Full support for modern desktop-class mobile processors.

## Custom Patches
If you need to modify the core `llama.cpp` behavior, it is recommended to apply your changes via the sync script or by modifying the `jni.cpp` bridge to maintain a clean upgrade path.
