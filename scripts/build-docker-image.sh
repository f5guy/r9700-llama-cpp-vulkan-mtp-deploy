#!/bin/bash
# Stage already-compiled llama.cpp Vulkan binaries and build the
# llama-cpp-vulkan:latest runtime image (fast: no in-container compile).
# Run scripts/build-vulkan-mtp.sh first to produce the build directory.

set -e

LLAMA_BUILD_BIN="${1:-$HOME/llama-mtp-vulkan/build/bin}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE_ROOT="$(mktemp -d)"
mkdir -p "$STAGE_ROOT/bin"

echo "=== Staging binaries from $LLAMA_BUILD_BIN ==="
cp -P "$LLAMA_BUILD_BIN"/llama-server \
      "$LLAMA_BUILD_BIN"/libggml-base.so* \
      "$LLAMA_BUILD_BIN"/libggml-cpu.so* \
      "$LLAMA_BUILD_BIN"/libggml-vulkan.so* \
      "$LLAMA_BUILD_BIN"/libggml.so* \
      "$LLAMA_BUILD_BIN"/libllama.so* \
      "$LLAMA_BUILD_BIN"/libllama-common.so* \
      "$LLAMA_BUILD_BIN"/libllama-server-impl.so \
      "$LLAMA_BUILD_BIN"/libmtmd.so* \
      "$STAGE_ROOT/bin/"

echo "=== Building llama-cpp-vulkan:latest ==="
docker build -t llama-cpp-vulkan:latest -f "$SCRIPT_DIR/../docker/Dockerfile.runtime" "$STAGE_ROOT"

rm -rf "$STAGE_ROOT"
echo "Done. Image: llama-cpp-vulkan:latest"
