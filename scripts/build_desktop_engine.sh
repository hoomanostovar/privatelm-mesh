#!/usr/bin/env bash
# Build script for Linux & macOS Desktop (llama.cpp + ggml-rpc-server)
# Usage: ./scripts/build_desktop_engine.sh [--cuda|--metal|--vulkan]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LLAMA_SRC="$ROOT_DIR/local_plugins/llama_flutter_android/android/src/main/cpp/llama.cpp"
BUILD_DIR="$ROOT_DIR/build_desktop"
BIN_DIR="$ROOT_DIR/bin"

mkdir -p "$BUILD_DIR"
mkdir -p "$BIN_DIR"

echo "=========================================================="
echo " Building PrivateLM-Mesh Desktop Engine (Unix/macOS)      "
echo "=========================================================="

CMAKE_ARGS=(
  "-S" "$LLAMA_SRC"
  "-B" "$BUILD_DIR"
  "-DCMAKE_BUILD_TYPE=Release"
  "-DGGML_RPC=ON"
  "-DGGML_BUILD_EXAMPLES=OFF"
  "-DGGML_BUILD_TESTS=OFF"
  "-DLLAMA_BUILD_EXAMPLES=ON"
  "-DLLAMA_BUILD_SERVER=ON"
)

OS_NAME="$(uname -s)"
if [ "$OS_NAME" = "Darwin" ]; then
  echo "[+] Enabling Apple Metal GPU Acceleration..."
  CMAKE_ARGS+=("-DGGML_METAL=ON")
elif [ "${1:-}" = "--cuda" ]; then
  echo "[+] Enabling NVIDIA CUDA Acceleration..."
  CMAKE_ARGS+=("-DGGML_CUDA=ON")
elif [ "${1:-}" = "--vulkan" ]; then
  echo "[+] Enabling Vulkan Acceleration..."
  CMAKE_ARGS+=("-DGGML_VULKAN=ON")
else
  echo "[+] Building CPU backend..."
fi

cmake "${CMAKE_ARGS[@]}"
cmake --build "$BUILD_DIR" --target rpc-server -j "$(getconf _NPROCESSORS_ONLN || nproc || sysctl -n hw.ncpu || echo 4)"

if [ -f "$BUILD_DIR/bin/rpc-server" ]; then
  cp "$BUILD_DIR/bin/rpc-server" "$BIN_DIR/rpc-server"
  chmod +x "$BIN_DIR/rpc-server"
  echo "[✓] Successfully built: $BIN_DIR/rpc-server"
else
  echo "[!] Could not locate built rpc-server in $BUILD_DIR/bin"
fi
