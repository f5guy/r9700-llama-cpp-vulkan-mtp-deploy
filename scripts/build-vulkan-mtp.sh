#!/bin/bash
# Build llama.cpp with Vulkan for AMD RDNA4 (gfx1201) — use this OR Docker
# Builds from the latest master branch (KHR_cooperative_matrix required)
# Tested on AMD RDNA4 (gfx1201) with RADV Mesa Vulkan

set -e

BUILD_DIR="${1:-$HOME/llama-mtp-vulkan}"

echo "=== Cloning latest llama.cpp master ==="
git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "$BUILD_DIR"

cd "$BUILD_DIR"

echo "=== Configuring with Vulkan + CPU ==="
cmake -B build \
    -DGGML_VULKAN=ON \
    -DGGML_CPU=ON \
    -DCMAKE_BUILD_TYPE=Release

echo "=== Building (using $(nproc) cores) ==="
cmake --build build --config Release -j$(nproc) --target llama-server

echo ""
echo "=== Build complete ==="
echo "  Binary:    $BUILD_DIR/build/bin/llama-server"
echo "  Libraries: $BUILD_DIR/build/bin/"
echo ""
echo "=== Next: build the Docker image (optional) ==="
echo "  ./build-docker-image.sh $BUILD_DIR/build/bin"
echo "  Then: docker compose up -d llama-27b   (see docker-compose.yml)"
