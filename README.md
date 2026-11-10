# PrivateLM-Mesh

> **Decentralized Heterogeneous AI Inference Cluster & Cross-Platform Client**  
> *Transform your personal devices into a cooperative high-performance local AI mesh.*  
> GitHub Repository: [https://github.com/hoomanostovar/privatelm-mesh](https://github.com/hoomanostovar/privatelm-mesh)

[![Release](https://img.shields.io/badge/Release-v1.1.4-blue?style=for-the-badge&logo=github)](https://github.com/hoomanostovar/privatelm-mesh/releases/latest)
[![Platforms](https://img.shields.io/badge/Platforms-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20Linux%20%7C%20iOS-brightgreen?style=for-the-badge)](https://github.com/hoomanostovar/privatelm-mesh/releases/latest)
[![License](https://img.shields.io/badge/License-MIT-yellow?style=for-the-badge)](./LICENSE)
[![Zero Dependencies](https://img.shields.io/badge/Zero_External_Dependencies-100%25_Out_of_the_Box-purple?style=for-the-badge)]()

---

## ⚡ What is PrivateLM-Mesh?

**PrivateLM-Mesh** unifies local on-device LLM inference across **Windows PCs, Apple Silicon Macs, Linux rigs, Android phones, and iOS tablets** into a unified collaborative compute cluster. By pooling system RAM and GPU VRAM over your local network (LAN / Wi-Fi / Ethernet), you can run massive open-weights models (such as **Qwen 2.5 32B, Llama 3.3 70B, DeepSeek-R1, and Gemma**) that would never fit on a single phone or laptop alone.

PrivateLM-Mesh is **completely self-contained and zero-setup**: all native inference binaries and desktop engines are bundled or auto-provisioned. You do not need Python, Docker, Ollama, or CUDA toolkits installed to get started.

---

## 🚀 Key Features

### 🌐 Decentralized Peer-to-Peer Mesh Network
- **Zero-Config LAN/Wi-Fi Discovery**: Nodes announce capability heartbeats every 4 seconds over UDP port `50053`. Automatic `/24` subnet unicast sweep guarantees discovery even across Wi-Fi/Ethernet router bridges and Android sleep locks.
- **Interactive Radar Scanner**: Visual 21st.dev-inspired radar display tracking all online cluster nodes, ping latencies, and device transport types in real time.
- **Dynamic Memory Pooling**: Automatically aggregates available VRAM and RAM across active nodes (`M_pool = ∑ VRAM_i + RAM_free_i`) and calculates whether your mesh can host 3B, 7B, 14B, 32B, or 70B models.

### 📦 Automated One-Click P2P Model Distribution
- **Direct P2P Model Sync**: Select any downloaded model on your primary device, mark target mesh nodes, and press **Distribute**. The model streams directly between devices over high-speed local Wi-Fi / Ethernet without eating internet bandwidth.
- **Auto-Sync on Mesh Join**: Newly connected phones, laptops, or PCs entering your local network can instantly join the cluster and auto-sync the active working model.
- **Smart Fallback**: If a peer node temporarily disconnects or experiences network interruptions, it seamlessly falls back to direct resume-capable origin fetching.

### ⚡ Heterogeneous Multi-GPU & CPU Layer Splitting (`ggml-rpc`)
- **Heterogeneous Compute**: Divide transformer model layers seamlessly across NVIDIA GeForce RTX (CUDA/DirectML), Apple Silicon (Metal), Android smartphones (Vulkan/NEON), and Linux servers.
- **Topology & Latency Optimized Scheduling**: Automatically measures link round-trip time (RTT) and node bandwidth (GB/s) to allocate layers proportionally to compute power without stalling the generation pipeline.
- **Headless Worker Daemons**: Dedicated background worker binaries (`rpc-server` and Rust daemon `privatelm-mesh-daemon`) run with `< 10 MB` memory footprint on homelabs and home servers.

### 📊 Real-Time Hardware Telemetry & Benchmarking
- **Bento Telemetry Cards**: Live tracking of mesh tokens generated, aggregate throughput (tokens/second), individual device uptime, real-time power draw (watts), and compute efficiency (tokens/watt).
- **Multi-Power-Tier Mesh Benchmark**: Built-in benchmark suite to stress-test your mesh cluster across 4 power profiles (**Eco, Balanced, Performance, Extreme**) to calculate maximum tokens/sec, KV cache throughput, and thermal headroom.

### 🎨 21st.dev Obsidian Glass UI
- **Crafted Aesthetic**: Deep obsidian canvas (`0xFF090A0D`), frosted glass cards (`GlowCard`) with ambient accent illumination, tactile spring-scaling haptic interactions (`InteractivePress`), and animated breathing status rings (`PulsingStatusDot`).
- **Floating Glass Dock**: Translucent, bottom-anchored floating dock with sliding illuminated pills for instant, fluid navigation between Chat, Models, Network Mesh, Tasks, and Settings.

### 🔒 100% Private, Autonomous, and Offline
- All chat sessions, parameters, embeddings, and prompt caches stay strictly inside your physical hardware. No telemetry, user data, or activations ever leave your local network.

---

## 📥 Downloads & Releases (v1.1.4 — Latest)

Always find the latest self-contained releases on the [**GitHub Releases Page**](https://github.com/hoomanostovar/privatelm-mesh/releases/latest).

| Platform | Local Inference & GPU Backend | Mesh Role | Package | Direct Download |
| :--- | :--- | :--- | :--- | :--- |
| **Android Phone / Tablet** | ✅ Vulkan / NEON / LiteRT | Coordinator & Worker | Standalone APK | [**`PrivateLM-Mesh-Android.apk`**](https://github.com/hoomanostovar/privatelm-mesh/releases/latest/download/PrivateLM-Mesh-Android.apk) |
| **Windows PC (x64)** | ✅ NVIDIA CUDA / Vulkan / DirectML / AVX2 | Coordinator & Worker | Portable ZIP | [**`PrivateLM-Mesh-Windows-x64.zip`**](https://github.com/hoomanostovar/privatelm-mesh/releases/latest/download/PrivateLM-Mesh-Windows-x64.zip) |
| **macOS (Apple Silicon)** | ✅ Apple Metal (M1/M2/M3/M4) | Coordinator & Worker | Portable ZIP | [**`PrivateLM-Mesh-macOS.zip`**](https://github.com/hoomanostovar/privatelm-mesh/releases/latest/download/PrivateLM-Mesh-macOS.zip) |
| **Linux (x64)** | ✅ Vulkan / CUDA / ROCm / AVX-512 | Coordinator & Worker | Tarball | [**`PrivateLM-Mesh-Linux-x64.tar.gz`**](https://github.com/hoomanostovar/privatelm-mesh/releases/latest/download/PrivateLM-Mesh-Linux-x64.tar.gz) |
| **Headless Windows Worker** | ✅ CUDA / Vulkan / CPU | Dedicated Worker | Worker Bundle | [**`PrivateLM-Mesh-Worker-Windows-x64.zip`**](https://github.com/hoomanostovar/privatelm-mesh/releases/latest/download/PrivateLM-Mesh-Worker-Windows-x64.zip) |
| **Ultra-Lightweight Daemon** | ⚡ Zero-dependency Rust | Dedicated Worker / Discovery | ZIP / Tarball | [**`privatelm-mesh-daemon`**](https://github.com/hoomanostovar/privatelm-mesh/releases/latest) |
| **iOS / iPad** | ✅ Apple Metal | Worker / Coordinator | Sideload IPA | *Available via AltStore / Sideloadly* |

---

## 🏗️ Architecture & How It Works

```
                        ┌──────────────────────────────────────────┐
                        │        Coordinator Node (Master)         │
                        │   Windows PC / Mac / Linux / Android     │
                        │     Hosts Full Model / Manages Mesh      │
                        └────────────────────┬─────────────────────┘
                                             │
             ┌───────────────────────────────┼───────────────────────────────┐
             │ ggml-rpc Layer Offload        │ P2P Model Distribution        │ UDP Mesh Beacons
             ▼                               ▼                               ▼
  ┌───────────────────────┐       ┌───────────────────────┐       ┌───────────────────────┐
  │     Worker Node 1     │       │     Worker Node 2     │       │     Worker Node 3     │
  │   NVIDIA RTX 4090     │       │   Apple Silicon M3    │       │   Android Smartphone  │
  │   VRAM: 24 GB (CUDA)  │       │   Unified: 36 GB (Metal)│     │   RAM: 12 GB (Vulkan) │
  │   Layers 0 -> 28      │       │   Layers 29 -> 54     │       │   Layers 55 -> 64     │
  └───────────────────────┘       └───────────────────────┘       └───────────────────────┘
```

### 1. Mesh Discovery & Zero-Config Pairing
- Every node runs `MeshDiscoveryService`, transmitting encrypted UDP beacons on port `50053` announcing hostname, GPU hardware, available VRAM, free RAM, and port endpoints.
- Automatic unicast `/24` subnet scanning overcomes AP isolation and Wi-Fi to Ethernet bridge packet filtering.

### 2. Heterogeneous Execution Pipeline
- When loading a model (e.g. `Qwen-2.5-32B-Instruct.gguf`), the coordinator divides the transformer layers according to each device's bandwidth and available memory.
- Compute is executed cooperatively over standard TCP sockets using `llama.cpp`'s high-efficiency `ggml-rpc`.

### 3. P2P Model Distribution
- Rather than having every phone and computer download gigabytes of model files from HuggingFace, one node downloads the model and serves it via an embedded HTTP chunked streaming server (`port 50054`).
- Target nodes download concurrently from the local server at full LAN speed (hundreds of megabytes per second).

---

## 🛠️ Build from Source

### Prerequisites
- **Flutter SDK:** `>=3.3.0` (Dart `>=3.3.0`)
- **C++ Compiler:** MSVC 2022 (Windows), Clang (macOS), GCC 12+ (Linux), Android NDK (API 26+)
- **CMake:** `>= 3.24`

### Windows Build
```powershell
git clone https://github.com/hoomanostovar/privatelm-mesh.git
cd privatelm-mesh
flutter pub get
flutter build windows --release
```
The output binary will be located in `build/windows/x64/runner/Release/`.

### Android Build
```bash
flutter pub get
flutter build apk --release
```
The output APK will be located in `build/app/outputs/flutter-apk/app-release.apk`.

### macOS Build
```bash
flutter pub get
flutter build macos --release
```

### Linux Build
```bash
flutter pub get
flutter build linux --release
```

### Rust Cluster Daemon (`privatelm-mesh-daemon`)
```bash
cd crates/privatelm-mesh-daemon
cargo build --release
```

---

## 📱 Hardware & Compatibility Matrix

| Hardware Vendor | Acceleration API | Supported Quantizations | Notes |
| :--- | :--- | :--- | :--- |
| **NVIDIA RTX / GTX** | CUDA / DirectML | Q2_K – Q8_0, FP16 | Full offload with Flash Attention |
| **Apple Silicon (M1-M4)** | Metal Performance Shaders | Q2_K – Q8_0, FP16 | High-bandwidth unified memory architecture |
| **Qualcomm Snapdragon** | Vulkan / Adreno | Q4_0, Q4_K_M, LiteRT-LM | Native mobile GPU acceleration |
| **Google Tensor (Pixel)** | CPU NEON / LiteRT-LM | Q4_0, Q5_K_M, LiteRT-LM | Robust single-thread and LiteRT scheduling |
| **MediaTek Dimensity** | Vulkan / Mali | Q4_0, Q4_K_M | Fully supported with FP16 sanitization |
| **x86_64 CPUs** | AVX2 / AVX-512 / OpenMP | All GGUF types | Automatic thread pool auto-tuning |

---

## 📄 License & Attribution

Distributed under the **MIT License**. See [`LICENSE`](./LICENSE) for full details.  
Originally based upon concepts in `cross-platform-llm-client` by orailnoor, massively expanded and re-architected by [Hooman Ostovar](https://github.com/hoomanostovar) into the decentralized PrivateLM-Mesh platform.
