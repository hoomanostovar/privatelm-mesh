# PrivateLM-Mesh Daemon (`privatelm-mesh-daemon`)

A high-performance, lightweight Rust daemon for pooling computing resources across PCs (Windows), Macs (macOS), Linux workstations, and Android/iOS mobile devices to run large language models in a distributed cluster.

---

## Capabilities

1. **Lightweight Headless Worker Node:**
   - Runs in the background as a system service or terminal command.
   - Consumes `< 10 MB` of idle RAM.
   - Supervises `ggml-rpc-server`, serving GPU (CUDA, Metal, Vulkan, ROCm) and CPU compute over TCP.
2. **Zero-Configuration LAN Discovery:**
   - Automatically announces node availability on local Wi-Fi or Ethernet via mDNS (`_privatelm._tcp`).
   - Automatically discovers other participating nodes on the local network.
3. **Hardware Benchmarking & Telemetry:**
   - Measures multi-threaded memory bandwidth (GB/s read throughput) to optimize token generation speed.
   - Probes network round-trip latency to prevent network bottlenecks.
4. **Local REST & WebSocket Control API:**
   - Exposes `127.0.0.1:50053` for the PrivateLM Flutter GUI desktop app to query status, toggle worker roles, and formulate cluster layer splits.

---

## Installation & Build

### Prerequisites
- [Rust & Cargo](https://rustup.rs/) (edition 2021+)
- CMake & C++ compiler (for building `llama.cpp` / `ggml-rpc-server`)

### Build Release Binary
```bash
cd crates/privatelm-mesh-daemon
cargo build --release
```
The compiled binary will be located at:
`target/release/privatelm-mesh-daemon` (or `.exe` on Windows).

---

## Usage

### 1. Run as a Worker Node (Default)
Lends this computer's GPU/RAM to any coordinator on the network:
```bash
privatelm-mesh-daemon --role worker --port 50052 --backend auto
```

### 2. Run as a Coordinator
Discovers available workers and coordinates distributed model execution:
```bash
privatelm-mesh-daemon --role coordinator
```

### 3. CLI Options
```
  -r, --role <ROLE>          [worker | coordinator | dual] [default: worker]
  -p, --port <PORT>          Listening port for RPC server [default: 50052]
      --control-port <PORT>  Listening port for control API [default: 50053]
  -t, --threads <THREADS>    CPU compute threads [default: 4]
  -b, --backend <BACKEND>    Compute accelerator (cuda, metal, rocm, vulkan, cpu) [default: auto]
  -n, --name <NAME>          Friendly display name (defaults to system hostname)
      --cache-dir <DIR>      Model weight cache directory [default: ./cluster_cache]
  -v, --verbose              Enable debug logging
```

---

## Running as a Background Daemon

### Windows (PowerShell as Administrator)
```powershell
New-Service -Name "PrivateLMMesh" -BinaryPathName "C:\Path\To\privatelm-mesh-daemon.exe --role worker" -StartupType Automatic
Start-Service "PrivateLMMesh"
```

### Linux (Systemd Service)
Create `/etc/systemd/system/privatelm-mesh.service`:
```ini
[Unit]
Description=PrivateLM-Mesh Worker Node
After=network.target

[Service]
ExecStart=/usr/local/bin/privatelm-mesh-daemon --role worker --backend auto
Restart=always
User=nobody

[Install]
WantedBy=multi-user.target
```
Enable and start:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now privatelm-mesh
```

### macOS (LaunchAgent)
Create `~/Library/LaunchAgents/com.privatelm.mesh.plist` with `ProgramArguments` pointing to the binary, then run:
```bash
launchctl load ~/Library/LaunchAgents/com.privatelm.mesh.plist
```
