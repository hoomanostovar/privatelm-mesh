# PrivateLM-Mesh: System Architecture & Design Specification

## 1. Executive Overview

**PrivateLM-Mesh** is a distributed, heterogeneous LLM inference and orchestration platform. It expands the mobile on-device LLM client ([PrivateLM](https://github.com/orailnoor/cross-platform-llm-client)) into a multiplatform cluster capable of pooling compute and memory resources across:
- **Desktop PCs** (Windows x86_64 / ARM64 with NVIDIA CUDA or Vulkan)
- **Apple Silicon Macs** (macOS ARM64 with Metal GPU unified memory)
- **Linux Workstations & Servers** (Linux x86_64 / AArch64 with CUDA, ROCm, or AVX-512)
- **Mobile Devices** (Android ARM64 & iOS Metal)

By utilizing `llama.cpp`'s low-level remote procedure call backend (`ggml-rpc`), model layers are split dynamically across physical devices connected via local Wi-Fi or Gigabit/10G Ethernet. Only the coordinator (Master) needs the GGUF model file on disk; workers receive and cache their assigned layer weights in RAM/VRAM over TCP during load.

---

## 2. System Topology

```
                                 ┌─────────────────────────────────┐
                                 │       GGUF Model on Disk        │
                                 │   (e.g., Llama-3.3-70B-Q4_K_M)  │
                                 └────────────────┬────────────────┘
                                                  │
                                                  ▼
                        ┌──────────────────────────────────────────────────┐
                        │              Master Coordinator                  │
                        │       (Flutter Desktop / Rust Daemon)            │
                        │                                                  │
                        │   • Reads Model Architecture & Layer Count       │
                        │   • Gathers Worker Bandwidth & Latency Telemetry │
                        │   • Computes Latency-Aware Layer Split           │
                        │   • Dispatches Weights & Evaluates Compute Graph │
                        └─────────────────────────┬────────────────────────┘
                                                  │
             ┌────────────────────────────────────┼────────────────────────────────────┐
             │ Gigabit LAN / Wi-Fi 6              │ Gigabit LAN / Wi-Fi 6              │
             ▼                                    ▼                                    ▼
┌──────────────────────────┐         ┌──────────────────────────┐         ┌──────────────────────────┐
│     Worker 1: PC         │         │     Worker 2: Mac M3     │         │   Worker 3: Phone/Linux  │
│  (Windows 11 / CUDA)     │         │   (macOS / Metal GPU)    │         │ (Android / Vulkan/CPU)   │
│                          │         │                          │         │                          │
│ • Runs ggml-rpc on :50052│         │ • Runs ggml-rpc on :50052│         │ • Runs ggml-rpc on :50052│
│ • Holds Layers 0-32      │         │ • Holds Layers 33-60     │         │ • Holds Layers 61-80     │
│ • 16 GB VRAM Cached      │         │ • 16 GB Unified Memory   │         │ • 8 GB Memory Cached     │
└──────────────────────────┘         └──────────────────────────┘         └──────────────────────────┘
```

---

## 3. Component Architecture

### A. Frontend Layer: Flutter Multiplatform
- **Directory:** `lib/`, `windows/`, `linux/`, `macos/`, `android/`, `ios/`, `web/`
- **Responsibilities:**
  - Modern, responsive Material 3 UI with desktop windowing support, multi-column layouts, and markdown chat bubbles.
  - Interactive Cluster Dashboard (`lib/views/cluster_view.dart`) visualizing node shares, memory allocation percentages, live bandwidth, and worker health.
  - Local SQLite/Hive persistence for session history, API keys, and paired workers.
  - Multi-provider fallback (OpenAI, Claude, Gemini, Kimi) when offline or off-cluster.

### B. Daemon & Networking Layer: Rust (`crates/privatelm-mesh-daemon`)
- **Directory:** `crates/privatelm-mesh-daemon/`
- **Responsibilities:**
  - **Zero-Config LAN Discovery (`src/discovery.rs`):** Uses mDNS / DNS-SD (`_privatelm._tcp.local.`) to advertise worker nodes and automatically detect peers.
  - **Hardware & Network Benchmarking (`src/bench.rs`):** Measures physical multi-threaded RAM read throughput (GB/s) and TCP RTT latency before assigning layers.
  - **Process Supervisor (`src/worker.rs`):** Spawns and manages `ggml-rpc-server`, tracks memory footprints, and handles clean terminations.
  - **Heterogeneous Planner (`src/coordinator.rs`):** Solves the combinatorial problem of allocating $N$ transformer layers across $M$ nodes of varying memory capacities and bus speeds.
  - **Local Control API (`src/api.rs`):** Lightweight Axum HTTP & WebSocket service on `127.0.0.1:50053` enabling the Flutter GUI to monitor status without native process coupling.

### C. Compute Engine: `llama.cpp` + `ggml-rpc`
- **Location:** `local_plugins/llama_flutter_android/android/src/main/cpp/llama.cpp`
- **Responsibilities:**
  - Fast, quantized matrix multiplication (Q4_0, Q4_K_M, Q5_K_M, Q8_0, FP16).
  - Multi-backend GPU support:
    - **CUDA** (NVIDIA RTX/GTX desktop and mobile GPUs)
    - **Metal** (Apple Silicon M1/M2/M3/M4 unified memory)
    - **Vulkan** (AMD Radeon, Intel Arc, and Android GPUs)
    - **CPU** (AVX2, AVX-512, NEON vector intrinsics)
  - Remote tensor evaluation: receives graph sub-evaluations over TCP, executes matrix multiplication locally, and sends intermediate activation tensors back.

---

## 4. Layer Allocation & Scheduling Algorithm

When the coordinator prepares to load a model:
1. **Capacity Check:**
   $$\text{RAM}_{\text{needed}} = \text{ModelSize}_{\text{MB}} \times 1.12$$
   If $\sum \text{Capacity}_i < \text{RAM}_{\text{needed}}$, the load aborts with an actionable error.
2. **Latency-Penalized Throughput Score:**
   Each node $i$ receives a performance score:
   $$\text{Score}_i = \frac{\text{Bandwidth}_{i}\text{ (GB/s)}}{1.0 + \max\left(0.1, \frac{\text{Latency}_{i}\text{ (ms)}}{15.0}\right)}$$
   Local compute has $0\text{ ms}$ latency penalty. Nodes with $> 120\text{ ms}$ ping are excluded to preserve generation interactivity.
3. **Discrete Layer Split:**
   Nodes are filled in order of score. The fractional memory allocated to each node maps directly to contiguous transformer layers:
   $$\text{Layers}_i = \text{round}\left(\frac{\text{AllocatedMB}_i}{\sum \text{AllocatedMB}} \times \text{TotalLayers}\right)$$

---

## 5. Development & Build Instructions

### 1. Build the Rust Daemon
```bash
cd crates/privatelm-mesh-daemon
cargo build --release
# Executable located at crates/privatelm-mesh-daemon/target/release/privatelm-mesh-daemon
```

### 2. Build the Desktop Compute Engine
- **Windows:**
  ```powershell
  .\scripts\build_desktop_engine.ps1 -Cuda   # For NVIDIA GPUs
  # OR
  .\scripts\build_desktop_engine.ps1         # For CPU / AVX2
  ```
- **macOS / Linux:**
  ```bash
  ./scripts/build_desktop_engine.sh          # Automatically selects Metal on Mac
  # OR
  ./scripts/build_desktop_engine.sh --cuda   # On Linux with NVIDIA
  ```

### 3. Run the Flutter Desktop App
```bash
flutter pub get
flutter run -d windows   # On Windows
flutter run -d macos     # On macOS
flutter run -d linux     # On Linux
```

