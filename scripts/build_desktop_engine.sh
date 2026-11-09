#!/usr/bin/env bash
# Build script for Linux & macOS Desktop (llama.cpp + ggml-rpc-server)
# Usage: ./scripts/build_desktop_engine.sh [--cuda|--metal|--vulkan]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build_desktop/build"
BIN_DIR="$ROOT_DIR/bin"
UPSTREAM_SRC="$ROOT_DIR/build_desktop/llama_cpp_upstream"

mkdir -p "$BUILD_DIR"
mkdir -p "$BIN_DIR"

if [ ! -f "$UPSTREAM_SRC/CMakeLists.txt" ]; then
  echo "[+] Fetching full upstream llama.cpp..."
  git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "$UPSTREAM_SRC"
fi
LLAMA_SRC="$UPSTREAM_SRC"

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
cmake --build "$BUILD_DIR" --target ggml-rpc-server -j "$(getconf _NPROCESSORS_ONLN || nproc || sysctl -n hw.ncpu || echo 4)"

CANDIDATE=""
for path in "$BUILD_DIR/bin/ggml-rpc-server" "$BUILD_DIR/bin/rpc-server" "$BUILD_DIR/bin/Release/ggml-rpc-server" "$BUILD_DIR/bin/Release/rpc-server"; do
  if [ -f "$path" ]; then
    CANDIDATE="$path"
    break
  fi
done

if [ -n "$CANDIDATE" ]; then
  cp "$CANDIDATE" "$BIN_DIR/rpc-server"
  cp "$CANDIDATE" "$BIN_DIR/ggml-rpc-server"
  chmod +x "$BIN_DIR/rpc-server" "$BIN_DIR/ggml-rpc-server"
  echo "[✓] Successfully built: $BIN_DIR/rpc-server"
else
  echo "[!] Could not locate built rpc-server in $BUILD_DIR/bin"
fi

