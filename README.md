# PrivateLM-Mesh

> **Decentralized Heterogeneous AI Inference Cluster & Cross-Platform Client**  
> *Pool memory and compute across your personal PCs, Macs, Linux machines, tablets, and phones to run local LLMs collaboratively.*  
> GitHub Repository: [https://github.com/hoomanostovar/privatelm-mesh](https://github.com/hoomanostovar/privatelm-mesh)

[![Release](https://img.shields.io/badge/Release-v1.2.0-blue?style=for-the-badge&logo=github)](https://github.com/hoomanostovar/privatelm-mesh/releases/latest)
[![Platforms](https://img.shields.io/badge/Platforms-Windows%20%7C%20Android%20%7C%20macOS%20%7C%20Linux%20%7C%20iOS-brightgreen?style=for-the-badge)](https://github.com/hoomanostovar/privatelm-mesh/releases/latest)
[![License](https://img.shields.io/badge/License-MIT-yellow?style=for-the-badge)](./LICENSE)

---

## ⚡ What is PrivateLM-Mesh?

**PrivateLM-Mesh** connects **Windows PCs, Apple Silicon Macs, Linux machines, Android phones, and tablets** into a local peer-to-peer compute mesh. By pooling available system RAM and GPU VRAM across your local network (LAN / Wi-Fi / Ethernet / USB-C ADB), you can split and run GGUF open-weights models across multiple devices or run smaller GGUF and LiteRT models directly on a single device.

PrivateLM-Mesh is self-contained: native desktop and mobile inference engines (`llama-server`, `rpc-server`, and Android JNI libraries) are bundled in the official release packages.

---

## 🚀 Key Features in v1.2.0

### 🌐 Hierarchy-Free Unified Peer-to-Peer Mesh
- **Equal-Peer Resource Pooling**: In **Unified Mesh Pool** mode, every device automatically runs its local RPC worker listener (`port 50052`) to lend memory to peers while simultaneously allowing you to load and chat with models from its own UI (`port 50051`). No manual Master vs. Worker hierarchy setup is required.
- **Instant Mode Switching (Zero Restart)**: Switch between **Unified Mesh Pool**, **Passive Worker**, and **Local Only** at any time without restarting the application.
- **Device Silhouette & Layer Stack Visualizer**: Visualizes every device in your active mesh using form-factor silhouettes (**PC Monitor**, **Tablet**, **Smartphone**) connected by directional pipeline arrows (`→`). Stacked horizontal layer bars inside each device silhouette animate how much of the selected model (`GB`, `%`, and layer range `L00–L32`) fits in each device's memory pool.
- **Persistent Mesh-Wide Device Renaming & Offline Identification**: Rename any device (e.g., `"Samsung S24 Kitchen"`, `"Living Room PC"`, `"Office Tablet"`) directly from the visualizer or device list. Custom names are persisted in local storage and synced across all mesh peers via UDP beacons and HTTP `/api/mesh/rename`. If one of several phones turns off, loses Wi-Fi, or crashes, it stays visible as **OFFLINE / UNREACHABLE** under its custom name so you immediately know which physical device needs attention.
- **Automatic LAN Discovery**: Nodes broadcast presence heartbeats every 4 seconds over UDP port `50053`, paired with an automatic `/24` subnet unicast sweep to traverse Wi-Fi/Ethernet router bridges.

### 📦 P2P Model Distribution & Live Receiving Telemetry
- **Direct LAN Model Push**: Select any downloaded GGUF model on one device, select target mesh peers, and stream the model directly over your local network (`port 50054`).
- **Receiving-Client Push Notifications & Auto-Load Confirmation**: When a model is pushed to a device, the receiving client immediately displays an incoming transfer toast and live progress bar (`%` and real-time `MB/s` speed) in both the Chat and Mesh views, refreshes its model catalog on completion, loads the model into memory, and sends a `sync-ack` confirmation back to the sender.

### 🧠 Reasoning Effort Controls, Context Compaction (`/compact`) & Chat UX
- **Selectable Model Reasoning Effort & Thinking Toggle**: Choose **Off (Instant)**, **Low (Brief)**, **Medium (Balanced)**, or **High (Deep)** reasoning effort directly from the Chat input bar, and toggle `<think>...</think>` trace visibility on or off. Includes built-in info-boxes explaining **Performance & Memory Penalties** (pre-reply thinking tokens, time-to-first-answer latency, KV cache usage) and **Expected Quality Improvements** (multi-step coding, math, logic, and self-correction).
- **Context Compaction (`/compact`)**: Condenses long chat histories into a structured `<CONTEXT_SUMMARY>` (*Primary Objectives*, *Key Constraints & Decisions*, *Technical Context & Files*, *Current State & Next Steps*) while keeping recent turns intact and clearing native KV cache slots. Works both with a loaded model and offline via a deterministic heuristic summarizer.
- **Unified Text Selection & Code Block Copying**: Select text continuously across paragraphs and bubbles, copy entire prompts or replies in one tap, or copy individual fenced code blocks via their language header bar.
- **GGUF vs. LiteRT Separation**: Clearly separates multi-device **GGUF (Mesh Cluster & Cross-Platform)** models from single-device **LiteRT (Android On-Device)** models in both Browse and My Models.

---

## 📥 Official Downloads (v1.2.0 — Latest)

Download the official `v1.2.0` binaries from the [**GitHub Releases Page**](https://github.com/hoomanostovar/privatelm-mesh/releases/tag/v1.2.0):

| Platform | Local Inference & GPU Backend | Mesh Role | Package | Direct Download |
| :--- | :--- | :--- | :--- | :--- |
| **Windows PC (x64)** | ✅ Vulkan / CUDA / CPU AVX2 | Unified Mesh / Coordinator / Worker | Portable ZIP | [**`PrivateLM-Mesh-Windows-x64.zip`**](https://github.com/hoomanostovar/privatelm-mesh/releases/download/v1.2.0/PrivateLM-Mesh-Windows-x64.zip) |
| **Android Phone / Tablet** | ✅ Vulkan / CPU NEON / LiteRT | Unified Mesh / Coordinator / Worker | Standalone APK | [**`PrivateLM-Mesh-Android.apk`**](https://github.com/hoomanostovar/privatelm-mesh/releases/download/v1.2.0/PrivateLM-Mesh-Android.apk) |
| **macOS (Apple Silicon)** | ✅ Apple Metal | Unified Mesh / Coordinator / Worker | Portable ZIP | [**`PrivateLM-Mesh-macOS.zip`**](https://github.com/hoomanostovar/privatelm-mesh/releases/download/v1.2.0/PrivateLM-Mesh-macOS.zip) |
| **Linux (x64)** | ✅ Vulkan / CUDA / CPU | Unified Mesh / Coordinator / Worker | Tarball | [**`PrivateLM-Mesh-Linux-x64.tar.gz`**](https://github.com/hoomanostovar/privatelm-mesh/releases/download/v1.2.0/PrivateLM-Mesh-Linux-x64.tar.gz) |
| **Headless Mesh Daemon** | ⚡ Rust Discovery & Worker Daemon | Background Worker | ZIP / Tarball | [**`privatelm-mesh-daemon-windows-x64.zip`**](https://github.com/hoomanostovar/privatelm-mesh/releases/download/v1.2.0/privatelm-mesh-daemon-windows-x64.zip) |

---

## 🏗️ How the Unified Mesh Works

```
  ┌──────────────────────┐       ┌──────────────────────┐       ┌──────────────────────┐
  │   Gaming PC (Local)  │       │   iPad / Android Tab │       │  Samsung Phone (USB) │
  │  [════════════════]  │       │   [══════════════]   │       │    [════════════]    │
  │  [════════════════]  │ ────► │   [══════════════]   │ ────► │    [════════════]    │
  │  [════════════════]  │  RPC  │   [══════════════]   │  RPC  │    [            ]    │
  │   Layers L00 – L16   │       │    Layers L17 – L26  │       │    Layers L27 – L32  │
  └──────────┴───────────┘       └──────────────────────┘       └──────────────────────┘
```

1. **Discovery & Persistent Naming (`UDP 50053` + `HTTP 50054`)**: Devices discover each other automatically on the LAN and sync user-defined device names so every phone, tablet, and PC is easy to identify—even if it goes offline.
2. **Proportional Layer Splitting (`ggml-rpc` on `TCP 50052`)**: When you load a GGUF model on any device in Unified Mesh Pool mode, layers are distributed across online peers according to interconnect priority (Local Bus → USB-C ADB → Ethernet → Wi-Fi) and available memory.
3. **Pre-Flight Socket Verification**: Before starting `llama-server`, each RPC endpoint is verified over TCP so an unreachable or powered-off peer is cleanly excluded without crashing the inference engine.

---

## 🛠️ Build from Source

### Prerequisites
- **Flutter SDK**: `>=3.3.0` (Dart `>=3.3.0`)
- **C++ Toolchain**: Visual Studio 2022 C++ workload (Windows), Xcode (macOS), Clang/GCC + CMake (Linux), Android NDK (Android)

### Windows (x64)
```powershell
git clone https://github.com/hoomanostovar/privatelm-mesh.git
cd privatelm-mesh
flutter pub get
flutter build windows --release
```
Output: `build/windows/x64/runner/Release/privatelm.exe`

### Android APK
```powershell
flutter pub get
flutter build apk --release
```
Output: `build/app/outputs/flutter-apk/app-release.apk`

---

## 📄 License

Distributed under the **MIT License**. See [`LICENSE`](./LICENSE) for details.
