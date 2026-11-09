//! PrivateLM-Mesh Cluster Daemon & Standalone Worker
//!
//! Entry point for the distributed cluster daemon. Enables Windows, macOS,
//! and Linux desktop machines or dedicated servers to pool their GPU and RAM
//! resources into a heterogeneous LLM cluster.

mod api;
mod bench;
mod coordinator;
mod discovery;
mod worker;

use anyhow::{Context, Result};
use clap::{Parser, ValueEnum};
use discovery::{DiscoveryManager, WorkerMetadata};
use std::path::PathBuf;
use std::sync::Arc;
use tracing::{info, Level};
use tracing_subscriber::FmtSubscriber;
use worker::WorkerSupervisor;

#[derive(Copy, Clone, PartialEq, Eq, PartialOrd, Ord, ValueEnum, Debug)]
enum Role {
    /// Act as a compute worker (serve local GPU/RAM to a master coordinator)
    Worker,
    /// Act as a master coordinator (discover workers and schedule inference)
    Coordinator,
    /// Dual mode (runs both coordinator and background worker)
    Dual,
}

#[derive(Parser, Debug)]
#[command(
    name = "privatelm-mesh-daemon",
    author = "Hooman Ostovar",
    version = "0.1.0",
    about = "Distributed Heterogeneous LLM Inference Cluster Daemon"
)]
struct Args {
    /// Operational role of this node
    #[arg(short, long, value_enum, default_value_t = Role::Worker)]
    role: Role,

    /// Listening port for the RPC worker service (ggml-rpc)
    #[arg(short, long, default_value_t = 50052)]
    port: u16,

    /// Listening port for local control & telemetry API
    #[arg(long, default_value_t = 50053)]
    control_port: u16,

    /// Number of CPU compute threads to allocate
    #[arg(short, long, default_value_t = 4)]
    threads: usize,

    /// Compute accelerator backend to prefer (cuda, metal, rocm, vulkan, cpu)
    #[arg(short, long, default_value = "auto")]
    backend: String,

    /// User-friendly name for this node (defaults to hostname)
    #[arg(short, long)]
    name: Option<String>,

    /// Cache directory for mapped model weights
    #[arg(long, default_value = "./cluster_cache")]
    cache_dir: PathBuf,

    /// Enable verbose debug logging
    #[arg(short, long)]
    verbose: bool,
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();

    // Initialize structured logging
    let log_level = if args.verbose {
        Level::DEBUG
    } else {
        Level::INFO
    };
    let subscriber = FmtSubscriber::builder()
        .with_max_level(log_level)
        .with_target(false)
        .finish();
    tracing::subscriber::set_global_default(subscriber)
        .context("Failed to set tracing subscriber")?;

    info!("Starting PrivateLM-Mesh Daemon v0.1.0");

    let device_name = args.name.unwrap_or_else(|| {
        hostname::get()
            .map(|h| h.to_string_lossy().to_string())
            .unwrap_or_else(|_| "Desktop-Node".to_string())
    });

    let node_id = uuid::Uuid::new_v4().to_string();
    let local_ip = local_ip_address::local_ip()
        .map(|ip| ip.to_string())
        .unwrap_or_else(|_| "127.0.0.1".to_string());

    info!(
        id = %node_id,
        name = %device_name,
        ip = %local_ip,
        role = ?args.role,
        "Node identity initialized"
    );

    // Initialize Worker Supervisor
    let supervisor = Arc::new(WorkerSupervisor::new(
        args.port,
        args.threads,
        args.backend.clone(),
        args.cache_dir,
    ));

    // Initialize mDNS Discovery
    let discovery = Arc::new(DiscoveryManager::new().context("Failed to initialize discovery")?);

    if args.role == Role::Worker || args.role == Role::Dual {
        // Measure memory bandwidth
        info!("Benchmarking local memory bandwidth...");
        let bandwidth_gbps = bench::measure_memory_bandwidth(args.threads);

        supervisor
            .start(bandwidth_gbps)
            .await
            .context("Failed to start worker")?;

        let (total_ram, free_ram) = WorkerSupervisor::query_ram();
        let meta = WorkerMetadata {
            id: node_id.clone(),
            name: device_name.clone(),
            host: local_ip.clone(),
            port: args.port,
            ram_mb: free_ram,
            bandwidth_gbps,
            os: std::env::consts::OS.to_string(),
            backend: args.backend.clone(),
        };

        if let Err(e) = discovery.register_worker(&meta) {
            tracing::warn!("mDNS announcement warning: {:#}", e);
        }
    }

    if args.role == Role::Coordinator || args.role == Role::Dual {
        info!("Starting mDNS browsing for peer workers...");
        discovery.start_browsing().context("Failed to start mDNS browsing")?;
    }

    // Start Local HTTP/WebSocket Control API
    let app_state = api::AppState {
        supervisor: Arc::clone(&supervisor),
        discovery: Arc::clone(&discovery),
    };

    let control_port = args.control_port;
    tokio::spawn(async move {
        if let Err(e) = api::ApiServer::run(app_state, control_port).await {
            tracing::error!("Control API error: {:#}", e);
        }
    });

    info!("PrivateLM-Mesh Daemon is operational. Press Ctrl+C to terminate.");
    tokio::signal::ctrl_c().await?;
    info!("Shutting down cluster daemon...");
    supervisor.stop().await?;

    Ok(())
}
