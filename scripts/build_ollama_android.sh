#!/usr/bin/env bash
# =============================================================================
# build_ollama_android.sh
# Cross-compile Ollama (llama.cpp backend) for Android ARM64
#
# Usage:
#   chmod +x scripts/build_ollama_android.sh
#   ./scripts/build_ollama_android.sh
#
# Output:
#   native/ollama-daemon/prebuilt/arm64/ollama
#   native/ollama-daemon/prebuilt/arm64/libllama.so
#   native/ollama-daemon/prebuilt/arm64/libggml*.so
#
# Requirements:
#   - Android NDK r26+ (set ANDROID_NDK_HOME)
#   - Go 1.22+ (for Ollama's Go bindings)
#   - CMake 3.22+
#   - ninja-build
#   - git
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
: "${ANDROID_NDK_HOME:=$HOME/Android/Sdk/ndk/26.3.11579264}"
ANDROID_API=34           # Android 14 (LineageOS 21)
ANDROID_ABI=arm64-v8a
ARCH_FLAGS="-march=armv8.2-a+fp16+dotprod+i8mm"  # Targets SD 855+ / A12+
OLLAMA_TAG="v0.5.7"      # Pin to a known-good release
LLAMA_CPP_TAG="b4730"    # llama.cpp snapshot bundled with this Ollama tag
NUM_JOBS=$(nproc)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$SCRIPT_DIR/_build"
OUTPUT_DIR="$REPO_ROOT/native/ollama-daemon/prebuilt/arm64"

TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64"
CC="$TOOLCHAIN/bin/aarch64-linux-android${ANDROID_API}-clang"
CXX="$TOOLCHAIN/bin/aarch64-linux-android${ANDROID_API}-clang++"
AR="$TOOLCHAIN/bin/llvm-ar"
STRIP="$TOOLCHAIN/bin/llvm-strip"

echo "========================================="
echo " AI-Native Android - Ollama Cross-Compile"
echo "========================================="
echo " NDK:         $ANDROID_NDK_HOME"
echo " API Level:   $ANDROID_API"
echo " ABI:         $ANDROID_ABI"
echo " Ollama tag:  $OLLAMA_TAG"
echo " Output:      $OUTPUT_DIR"
echo ""

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------
check_tool() {
    command -v "$1" &>/dev/null || { echo "ERROR: $1 not found. Please install it."; exit 1; }
}
check_tool cmake
check_tool ninja
check_tool go
check_tool git

if [ ! -f "$CC" ]; then
    echo "ERROR: NDK compiler not found at $CC"
    echo "  Set ANDROID_NDK_HOME to your NDK installation path."
    exit 1
fi

GO_VERSION=$(go version | awk '{print $3}' | sed 's/go//')
echo "Go version: $GO_VERSION"

mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

# ---------------------------------------------------------------------------
# Step 1: Clone / update llama.cpp
# ---------------------------------------------------------------------------
echo ""
echo "[1/4] Preparing llama.cpp source..."
LLAMA_SRC="$BUILD_DIR/llama.cpp"
if [ ! -d "$LLAMA_SRC/.git" ]; then
    git clone --depth=1 https://github.com/ggml-org/llama.cpp.git "$LLAMA_SRC"
else
    git -C "$LLAMA_SRC" fetch --depth=1
    git -C "$LLAMA_SRC" reset --hard HEAD
fi

# ---------------------------------------------------------------------------
# Step 2: Cross-compile llama.cpp shared libraries for ARM64
# ---------------------------------------------------------------------------
echo ""
echo "[2/4] Cross-compiling llama.cpp for $ANDROID_ABI..."
LLAMA_BUILD="$BUILD_DIR/llama-android-build"
mkdir -p "$LLAMA_BUILD"

cmake -S "$LLAMA_SRC" -B "$LLAMA_BUILD" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$ANDROID_ABI" \
    -DANDROID_PLATFORM="android-${ANDROID_API}" \
    -DCMAKE_C_FLAGS="$ARCH_FLAGS" \
    -DCMAKE_CXX_FLAGS="$ARCH_FLAGS" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DGGML_OPENMP=OFF \
    -DGGML_LLAMAFILE=OFF \
    -DGGML_VULKAN=OFF \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_SERVER=OFF

cmake --build "$LLAMA_BUILD" --config Release -j"$NUM_JOBS"

# Copy shared libraries
echo "  Copying llama.cpp libraries..."
find "$LLAMA_BUILD" -name "*.so" -exec cp {} "$OUTPUT_DIR/" \;

# ---------------------------------------------------------------------------
# Step 3: Clone / update Ollama and build for Android
# ---------------------------------------------------------------------------
echo ""
echo "[3/4] Building Ollama Go server for Android..."
OLLAMA_SRC="$BUILD_DIR/ollama"
if [ ! -d "$OLLAMA_SRC/.git" ]; then
    git clone --depth=1 --branch "$OLLAMA_TAG" https://github.com/ollama/ollama.git "$OLLAMA_SRC"
else
    git -C "$OLLAMA_SRC" fetch --depth=1
    git -C "$OLLAMA_SRC" checkout "$OLLAMA_TAG" 2>/dev/null || true
fi

# Ollama uses CGO to link against llama.cpp
# We provide the prebuilt llama.cpp libs from step 2
export GOOS=android
export GOARCH=arm64
export CGO_ENABLED=1
export CC="$CC"
export CXX="$CXX"
export AR="$AR"
export CGO_CFLAGS="-I$LLAMA_SRC/include -I$LLAMA_SRC/ggml/include $ARCH_FLAGS -D__ANDROID__ -DGGML_USE_LLAMAFILE=0"
export CGO_LDFLAGS="-L$OUTPUT_DIR -lllama -lggml -static-libstdc++"

cd "$OLLAMA_SRC"
go build \
    -ldflags="-s -w -extldflags '-Wl,--allow-shlib-undefined'" \
    -tags 'android' \
    -o "$OUTPUT_DIR/ollama" \
    ./.

echo "  ollama binary: $OUTPUT_DIR/ollama"
file "$OUTPUT_DIR/ollama"

# ---------------------------------------------------------------------------
# Step 4: Strip and verify
# ---------------------------------------------------------------------------
echo ""
echo "[4/4] Stripping and verifying..."
"$STRIP" --strip-unneeded "$OUTPUT_DIR/ollama" 2>/dev/null || true
for lib in "$OUTPUT_DIR"/*.so; do
    "$STRIP" --strip-unneeded "$lib" 2>/dev/null || true
done

echo ""
echo "Build artifacts:"
ls -lh "$OUTPUT_DIR"/

echo ""
echo "========================================="
echo " SUCCESS: Ollama built for Android ARM64"
echo "========================================="
echo ""
echo "Next steps:"
echo "  1. Copy prebuilts into your LineageOS tree:"
echo "     cp $OUTPUT_DIR/ollama <lineage-src>/device/<vendor>/<device>/prebuilt/ollama"
echo "  2. Add to your device Android.mk or PRODUCT_PACKAGES:"
echo "     PRODUCT_PACKAGES += ollama"
echo "  3. Build the full ROM:"
echo "     source build/envsetup.sh && breakfast <device> && brunch <device>"
echo "  4. Flash and check daemon status:"
echo "     adb shell getprop init.svc.ollama"
echo "  5. Test inference:"
echo "     adb shell service call ai_native_service 1 s16 'Hello from ROM'"
