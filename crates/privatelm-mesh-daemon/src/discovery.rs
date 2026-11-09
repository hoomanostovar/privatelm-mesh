//! Zero-Configuration Peer Discovery (mDNS / DNS-SD)
//!
//! Advertises the worker node to the local network using the service type `_privatelm._tcp.local.`
//! compatible with the mobile PrivateLM app, and discovers other workers.

use anyhow::{Context, Result};
use mdns_sd::{ServiceDaemon, ServiceEvent, ServiceInfo};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::{error, info, warn};

pub const SERVICE_TYPE: &str = "_privatelm._tcp.local.";

/// Metadata payload broadcasted by a cluster worker node
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkerMetadata {
    pub id: String,
    pub name: String,
    pub host: String,
    pub port: u16,
    pub ram_mb: u64,
    pub bandwidth_gbps: f64,
    pub os: String,
    pub backend: String,
}

pub struct DiscoveryManager {
    daemon: ServiceDaemon,
    discovered_workers: Arc<RwLock<HashMap<String, WorkerMetadata>>>,
}

impl DiscoveryManager {
    pub fn new() -> Result<Self> {
        let daemon = ServiceDaemon::new().context("Failed to initialize mDNS ServiceDaemon")?;
        Ok(Self {
            daemon,
            discovered_workers: Arc::new(RwLock::new(HashMap::new())),
        })
    }

    /// Advertises this machine as an active cluster worker on the local subnet.
    pub fn register_worker(&self, meta: &WorkerMetadata) -> Result<()> {
        let instance_name = format!("PrivateLM-{}", &meta.id[..8.min(meta.id.len())]);
        let host_name = format!("{}.local.", instance_name);

        let mut properties = HashMap::new();
        properties.insert("id".to_string(), meta.id.clone());
        properties.insert("name".to_string(), meta.name.clone());
        properties.insert("ram".to_string(), meta.ram_mb.to_string());
        properties.insert("bw".to_string(), format!("{:.1}", meta.bandwidth_gbps));
        properties.insert("os".to_string(), meta.os.clone());
        properties.insert("backend".to_string(), meta.backend.clone());

        let service_info = ServiceInfo::new(
            SERVICE_TYPE,
            &instance_name,
            &host_name,
            &meta.host,
            meta.port,
            properties,
        )
        .context("Failed to create mDNS ServiceInfo")?;

        self.daemon
            .register(service_info)
            .context("Failed to register mDNS service")?;

        info!(
            instance = instance_name,
            port = meta.port,
            "Broadcasting worker via mDNS (_privatelm._tcp)"
        );

        Ok(())
    }

    /// Starts continuously scanning for other cluster workers on the network.
    pub fn start_browsing(&self) -> Result<()> {
        let receiver = self
            .daemon
            .browse(SERVICE_TYPE)
            .context("Failed to start mDNS browse receiver")?;

        let workers_store = Arc::clone(&self.discovered_workers);

        tokio::spawn(async move {
            while let Ok(event) = receiver.recv_async().await {
                match event {
                    ServiceEvent::ServiceResolved(info) => {
                        let props = info.get_properties();
                        let id = props
                            .get_property_val_str("id")
                            .unwrap_or("unknown")
                            .to_string();
                        let name = props
                            .get_property_val_str("name")
                            .unwrap_or(info.get_fullname())
                            .to_string();
                        let ram_mb = props
                            .get_property_val_str("ram")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0);
                        let bandwidth_gbps = props
                            .get_property_val_str("bw")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0.0);
                        let os = props
                            .get_property_val_str("os")
                            .unwrap_or("unknown")
                            .to_string();
                        let backend = props
                            .get_property_val_str("backend")
                            .unwrap_or("cpu")
                            .to_string();

                        let host = info
                            .get_addresses()
                            .iter()
                            .find(|ip| ip.is_ipv4())
                            .map(|ip| ip.to_string())
                            .unwrap_or_else(|| "127.0.0.1".to_string());

                        let worker = WorkerMetadata {
                            id: id.clone(),
                            name,
                            host,
                            port: info.get_port(),
                            ram_mb,
                            bandwidth_gbps,
                            os,
                            backend,
                        };

                        info!(worker = ?worker, "Discovered cluster worker on LAN");
                        workers_store.write().await.insert(id, worker);
                    }
                    ServiceEvent::ServiceRemoved(_service_type, fullname) => {
                        info!(fullname = fullname, "Worker removed from LAN");
                        workers_store
                            .write()
                            .await
                            .retain(|_, v| !fullname.contains(&v.name));
                    }
                    _ => {}
                }
            }
        });

        Ok(())
    }

    /// Returns a snapshot of all discovered workers currently reachable.
    pub async fn get_workers(&self) -> Vec<WorkerMetadata> {
        self.discovered_workers.read().await.values().cloned().collect()
    }
}
