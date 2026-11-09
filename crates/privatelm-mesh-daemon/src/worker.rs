//! Worker Node Supervisor
//!
//! Manages the lifecycle of the local RPC worker instance (ggml-rpc-server),
//! monitors local memory allocation, CPU/GPU utilization, and reports telemetry.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use sysinfo::{MemoryRefreshKind, RefreshKind, System};
use tokio::process::{Child, Command};
use tokio::sync::RwLock;
use tracing::{error, info, warn};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkerStatus {
    pub state: String, // "starting", "running", "stopped", "error"
    pub peer: Option<String>,
    pub held_mb: u64,
    pub free_ram_mb: u64,
    pub total_ram_mb: u64,
    pub bandwidth_gbps: f64,
    pub port: u16,
    pub backend: String,
    pub last_error: Option<String>,
}

pub struct WorkerSupervisor {
    port: u16,
    threads: usize,
    backend: String,
    cache_dir: PathBuf,
    status: Arc<RwLock<WorkerStatus>>,
    running: Arc<AtomicBool>,
    child_process: Arc<tokio::sync::Mutex<Option<Child>>>,
}

impl WorkerSupervisor {
    pub fn new(port: u16, threads: usize, backend: String, cache_dir: PathBuf) -> Self {
        let (total_ram, free_ram) = Self::query_ram();
        let status = WorkerStatus {
            state: "stopped".to_string(),
            peer: None,
            held_mb: 0,
            free_ram_mb: free_ram,
            total_ram_mb: total_ram,
            bandwidth_gbps: 0.0,
            port,
            backend: backend.clone(),
            last_error: None,
        };

        Self {
            port,
            threads,
            backend,
            cache_dir,
            status: Arc::new(RwLock::new(status)),
            running: Arc::new(AtomicBool::new(false)),
            child_process: Arc::new(tokio::sync::Mutex::new(None)),
        }
    }

    /// Queries system RAM in megabytes.
    pub fn query_ram() -> (u64, u64) {
        let mut sys = System::new_with_specifics(
            RefreshKind::new().with_memory(MemoryRefreshKind::everything()),
        );
        sys.refresh_memory();
        let total_mb = sys.total_memory() / (1024 * 1024);
        let free_mb = sys.available_memory() / (1024 * 1024);
        (total_mb, free_mb)
    }

    /// Starts the worker service.
    /// Finds or invokes `rpc-server` / `ggml-rpc-server` or the embedded native library.
    pub async fn start(&self, bandwidth_gbps: f64) -> Result<()> {
        if self.running.load(Ordering::SeqCst) {
            return Ok(());
        }

        std::fs::create_dir_all(&self.cache_dir).context("Failed to create worker cache directory")?;

        let (_, free_ram) = Self::query_ram();
        {
            let mut s = self.status.write().await;
            s.state = "starting".to_string();
            s.free_ram_mb = free_ram;
            s.bandwidth_gbps = bandwidth_gbps;
        }

        info!(
            port = self.port,
            threads = self.threads,
            backend = %self.backend,
            free_ram_mb = free_ram,
            "Launching RPC worker node"
        );

        // Attempt to launch ggml-rpc-server binary if found in PATH or adjacent directories
        let binary_names = ["rpc-server", "ggml-rpc-server", "rpc-server.exe", "ggml-rpc-server.exe"];
        let mut executable: Option<PathBuf> = None;

        for name in &binary_names {
            if let Ok(path) = which::which(name) {
                executable = Some(path);
                break;
            }
        }

        // Also check relative build directories
        if executable.is_none() {
            let candidate_paths = [
                PathBuf::from("./bin").join("rpc-server"),
                PathBuf::from("./bin").join("rpc-server.exe"),
                PathBuf::from("../build").join("rpc-server"),
            ];
            for p in &candidate_paths {
                if p.exists() {
                    executable = Some(p.clone());
                    break;
                }
            }
        }

        if let Some(bin) = executable {
            info!(path = ?bin, "Starting external ggml-rpc-server process");
            let mut cmd = Command::new(&bin);
            cmd.arg("-p")
                .arg(self.port.to_string())
                .arg("-t")
                .arg(self.threads.to_string())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped());

            let child = cmd.spawn().context("Failed to spawn rpc-server process")?;
            let mut proc_guard = self.child_process.lock().await;
            *proc_guard = Some(child);
        } else {
            warn!(
                "No external rpc-server executable found in PATH. Ensure ggml-rpc-server binary is placed in ./bin or PATH."
            );
        }

        self.running.store(true, Ordering::SeqCst);
        {
            let mut s = self.status.write().await;
            s.state = "running".to_string();
        }

        Ok(())
    }

    /// Stops the worker service.
    pub async fn stop(&self) -> Result<()> {
        self.running.store(false, Ordering::SeqCst);

        let mut proc_guard = self.child_process.lock().await;
        if let Some(mut child) = proc_guard.take() {
            let _ = child.kill().await;
        }

        let mut s = self.status.write().await;
        s.state = "stopped".to_string();
        s.peer = None;
        s.held_mb = 0;
        info!("Cluster worker stopped");
        Ok(())
    }

    pub async fn get_status(&self) -> WorkerStatus {
        let mut s = self.status.read().await.clone();
        let (_, free) = Self::query_ram();
        s.free_ram_mb = free;
        s
    }
}
