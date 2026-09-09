cmake_minimum_required(VERSION 3.10)

project("llamacppkt")

set(CMAKE_CXX_STANDARD 17)
set(RNLLAMA_LIB_DIR ${CMAKE_SOURCE_DIR}/lib)

include_directories(
    ${RNLLAMA_LIB_DIR}
    ${RNLLAMA_LIB_DIR}/common
    ${RNLLAMA_LIB_DIR}/common/jinja
    ${RNLLAMA_LIB_DIR}/ggml-cpu
    ${RNLLAMA_LIB_DIR}/tools/mtmd
)

# Collect source files using glob patterns
file(GLOB MODEL_FILES ${RNLLAMA_LIB_DIR}/models/*.cpp)
file(GLOB GGML_CPU_C_FILES ${RNLLAMA_LIB_DIR}/ggml-cpu/*.c)
file(GLOB GGML_CPU_CPP_FILES ${RNLLAMA_LIB_DIR}/ggml-cpu/*.cpp)
file(GLOB GGML_CPU_AMX_FILES ${RNLLAMA_LIB_DIR}/ggml-cpu/amx/*.cpp)
file(GLOB LLAMA_FILES ${RNLLAMA_LIB_DIR}/llama*.cpp)
file(GLOB MTMD_FILES ${RNLLAMA_LIB_DIR}/tools/mtmd/*.cpp)
file(GLOB MTMD_MODEL_FILES ${RNLLAMA_LIB_DIR}/tools/mtmd/models/*.cpp)
file(GLOB COMMON_FILES ${RNLLAMA_LIB_DIR}/common/*.cpp)
file(GLOB JINJA_FILES ${RNLLAMA_LIB_DIR}/common/jinja/*.cpp)

# Source files for the shared library
set(
    SOURCE_FILES
    # Core GGML files
    ${RNLLAMA_LIB_DIR}/ggml.c
    ${RNLLAMA_LIB_DIR}/ggml-alloc.c
    ${RNLLAMA_LIB_DIR}/ggml-backend.cpp
    ${RNLLAMA_LIB_DIR}/ggml-backend-dl.cpp
    ${RNLLAMA_LIB_DIR}/ggml-backend-reg.cpp
    ${RNLLAMA_LIB_DIR}/ggml-opt.cpp
    ${RNLLAMA_LIB_DIR}/ggml-threading.cpp
    ${RNLLAMA_LIB_DIR}/ggml-quants.c
    ${RNLLAMA_LIB_DIR}/gguf.cpp

    # GGML CPU files (globbed)
    ${GGML_CPU_C_FILES}
    ${GGML_CPU_CPP_FILES}
    ${GGML_CPU_AMX_FILES}

    # Llama files (globbed)
    ${LLAMA_FILES}
    ${RNLLAMA_LIB_DIR}/unicode-data.cpp
    ${RNLLAMA_LIB_DIR}/unicode.cpp

    # Common utilities
    ${COMMON_FILES}

    ${RNLLAMA_LIB_DIR}/anyascii.c

    # Jinja template engine
    ${JINJA_FILES}

    # Multimodal support (globbed)
    ${MTMD_MODEL_FILES}
    ${MTMD_FILES}

    # React Native llama APIs (used by our JNI)
    ${RNLLAMA_LIB_DIR}/rn-llama.cpp
    ${RNLLAMA_LIB_DIR}/rn-completion.cpp
    ${RNLLAMA_LIB_DIR}/rn-tts.cpp
    ${RNLLAMA_LIB_DIR}/rn-slot.cpp
    ${RNLLAMA_LIB_DIR}/rn-slot-manager.cpp

    # Model implementations (globbed)
    ${MODEL_FILES}
    
    # Our JNI wrapper
    ${CMAKE_SOURCE_DIR}/jni.cpp
)

find_library(LOG_LIB log)

function(build_library target_name arch cpu_flags)
    if (NOT ${arch} STREQUAL "generic")
        set(SOURCE_FILES_ARCH
            ${RNLLAMA_LIB_DIR}/ggml-cpu/arch/${arch}/quants.c
            ${RNLLAMA_LIB_DIR}/ggml-cpu/arch/${arch}/repack.cpp
        )
    endif ()

    add_library(
            ${target_name}
            SHARED
            ${SOURCE_FILES}
            ${SOURCE_FILES_ARCH}
    )

    target_link_libraries(${target_name} ${LOG_LIB} android)

    if (${arch} STREQUAL "generic")
        target_compile_options(${target_name} PRIVATE -DLM_GGML_CPU_GENERIC)
    endif ()

    target_compile_options(${target_name} PRIVATE 
        -DLM_GGML_USE_CPU 
        -DLM_GGML_USE_CPU_REPACK 
        -pthread 
        ${cpu_flags} 
        -fvectorize 
        -ffp-model=fast 
        -fno-finite-math-only 
        -flto 
        -D_GNU_SOURCE
        -DRNLLAMA_USE_FD_FILE
    )

    if (${CMAKE_BUILD_TYPE} STREQUAL "Debug")
        target_compile_options(${target_name} PRIVATE -DRNLLAMA_ANDROID_ENABLE_LOGGING)
    endif ()

    target_compile_options(${target_name} PRIVATE -O3 -DNDEBUG)
    target_compile_options(${target_name} PRIVATE -fvisibility=hidden -fvisibility-inlines-hidden)
    target_compile_options(${target_name} PRIVATE -ffunction-sections -fdata-sections)

    target_link_options(${target_name} PRIVATE -Wl,--gc-sections)
    target_link_options(${target_name} PRIVATE -Wl,--exclude-libs,ALL)
    target_link_options(${target_name} PRIVATE -flto)
endfunction()


# Default target (no specific CPU features)
build_library("rnllama" "generic" "")

if (${ANDROID_ABI} STREQUAL "arm64-v8a")
    # ARM64 targets
    build_library("rnllama_v8" "arm" "-march=armv8-a")
    build_library("rnllama_v8_2" "arm" "-march=armv8.2-a")
    build_library("rnllama_v8_2_dotprod" "arm" "-march=armv8.2-a+dotprod")
    build_library("rnllama_v8_2_i8mm" "arm" "-march=armv8.2-a+i8mm")
    build_library("rnllama_v8_2_dotprod_i8mm" "arm" "-march=armv8.2-a+dotprod+i8mm")
    # Add other variants if needed, mirroring cui-llama.rn
elseif (${ANDROID_ABI} STREQUAL "x86_64")
    # x86_64 target
    build_library("rnllama_x86_64" "x86" "-march=x86-64;-mtune=generic;-msse4.2;-mpopcnt")
endif ()
