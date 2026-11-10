//! Heterogeneous Cluster Coordinator & Layer Placement Engine
//!
//! Formulates optimal layer distribution plans across heterogeneous nodes
//! (Windows PC, Apple Silicon Mac, Linux Server, Android/iOS) based on:
//! 1. Memory capacity (VRAM / RAM)
//! 2. Memory bandwidth (GB/s read throughput)
//! 3. Network latency & interconnect quality

use serde::{Deserialize, Serialize};
use tracing::info;

fn default_transport() -> String {
    "unknown".to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClusterNode {
    pub id: String,
    pub name: String,
    pub endpoint: String,
    pub capacity_mb: f64,
    pub bandwidth_gbps: f64,
    pub latency_ms: f64,
    pub is_local: bool,
    #[serde(default = "default_transport")]
    pub transport_type: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NodeAllocation {
    pub node_id: String,
    pub name: String,
    pub endpoint: String,
    pub allocated_mb: f64,
    pub layer_start: usize,
    pub layer_count: usize,
    pub split_fraction: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClusterPlan {
    pub total_model_mb: f64,
    pub total_layers: usize,
    pub allocations: Vec<NodeAllocation>,
    pub expected_tokens_per_sec: f64,
}

pub struct ClusterCoordinator;

impl ClusterCoordinator {
    /// Formulates a model allocation plan across participating cluster nodes.
    ///
    /// Implements weighted latency-aware pipeline splitting:
    /// - High bandwidth nodes are weighted higher.
    /// - Direct interconnects (Local, USB-C via ADB, Gigabit Ethernet) are tiered above Wi-Fi.
    /// - If the model fits within wired/direct tiers, Wi-Fi nodes are gated to prevent activation latency penalties.
    pub fn plan_distribution(
        mut nodes: Vec<ClusterNode>,
        model_size_mb: f64,
        total_layers: usize,
    ) -> Result<ClusterPlan, String> {
        let needed_mb = model_size_mb * 1.12; // Weights + KV cache buffers

        // Filter out unreachable or severely lagged nodes (> 120ms ping)
        nodes.retain(|n| n.is_local || (n.latency_ms < 120.0 && n.capacity_mb > 500.0));

        let total_capacity: f64 = nodes.iter().map(|n| n.capacity_mb).sum();
        if needed_mb > total_capacity {
            return Err(format!(
                "Model requires {:.1} GB, but available cluster capacity is only {:.1} GB across {} node(s).",
                needed_mb / 1024.0,
                total_capacity / 1024.0,
                nodes.len()
            ));
        }

        // Tiering: Local -> USB -> Ethernet -> Wi-Fi
        // If the model fits completely within Local + USB + Ethernet,
        // gate Wi-Fi nodes to eliminate activation round-trip latency overhead.
        let low_latency_capacity: f64 = nodes
            .iter()
            .filter(|n| n.is_local || n.transport_type == "usb" || n.transport_type == "ethernet" || n.latency_ms <= 2.0)
            .map(|n| n.capacity_mb)
            .sum();

        let gate_wifi = needed_mb <= low_latency_capacity;

        // Calculate node score: (Bandwidth * Transport Multiplier) / (1.0 + Latency penalty)
        let mut scored_nodes: Vec<(ClusterNode, f64)> = nodes
            .into_iter()
            .filter(|node| {
                if gate_wifi && !node.is_local && node.transport_type == "wifi" && node.latency_ms > 2.0 {
                    return false;
                }
                true
            })
            .map(|node| {
                let transport_mult = match node.transport_type.as_str() {
                    "usb" => 3.0,
                    "ethernet" => 2.0,
                    _ if node.is_local => 4.0,
                    _ => 1.0,
                };
                let latency_penalty = if node.is_local {
                    0.0
                } else {
                    (node.latency_ms / 10.0).max(0.05)
                };
                let score = (node.bandwidth_gbps * transport_mult) / (1.0 + latency_penalty);
                (node, score)
            })
            .collect();

        // Sort descending by score (fastest, lowest latency first)
        scored_nodes.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

        // Greedy fill with proportional smoothing
        let mut remaining_mb = needed_mb;
        let mut intermediate_allocations: Vec<(ClusterNode, f64)> = Vec::new();

        for (node, _) in &scored_nodes {
            if remaining_mb <= 0.0 {
                break;
            }
            let alloc_mb = node.capacity_mb.min(remaining_mb);
            remaining_mb -= alloc_mb;
            intermediate_allocations.push((node.clone(), alloc_mb));
        }

        // Map allocated MB to discrete layers
        let total_allocated: f64 = intermediate_allocations.iter().map(|(_, mb)| *mb).sum();
        let mut current_layer = 0;
        let mut allocations = Vec::new();

        for (idx, (node, mb)) in intermediate_allocations.iter().enumerate() {
            let is_last = idx == intermediate_allocations.len() - 1;
            let fraction = mb / total_allocated;
            let layer_count = if is_last {
                total_layers.saturating_sub(current_layer)
            } else {
                ((fraction * total_layers as f64).round() as usize).min(total_layers.saturating_sub(current_layer))
            };

            allocations.push(NodeAllocation {
                node_id: node.id.clone(),
                name: node.name.clone(),
                endpoint: node.endpoint.clone(),
                allocated_mb: *mb,
                layer_start: current_layer,
                layer_count,
                split_fraction: fraction,
            });

            current_layer += layer_count;
        }

        let plan = ClusterPlan {
            total_model_mb: model_size_mb,
            total_layers,
            allocations,
            expected_tokens_per_sec: 14.0, // Baseline estimate
        };

        info!(
            model_mb = model_size_mb,
            layers = total_layers,
            nodes = plan.allocations.len(),
            "Cluster distribution plan formulated"
        );

        Ok(plan)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_gate_wifi_when_fits_in_usb_and_local() {
        let nodes = vec![
            ClusterNode {
                id: "local".to_string(),
                name: "PC (RTX 4090)".to_string(),
                endpoint: "127.0.0.1:50051".to_string(),
                capacity_mb: 16000.0,
                bandwidth_gbps: 1008.0,
                latency_ms: 0.0,
                is_local: true,
                transport_type: "unknown".to_string(),
            },
            ClusterNode {
                id: "usb-phone".to_string(),
                name: "Galaxy S24 (USB-C)".to_string(),
                endpoint: "127.0.0.1:50052".to_string(),
                capacity_mb: 8000.0,
                bandwidth_gbps: 50.0,
                latency_ms: 0.3,
                is_local: false,
                transport_type: "usb".to_string(),
            },
            ClusterNode {
                id: "wifi-tablet".to_string(),
                name: "Tablet (Wi-Fi)".to_string(),
                endpoint: "192.168.1.150:50052".to_string(),
                capacity_mb: 6000.0,
                bandwidth_gbps: 30.0,
                latency_ms: 25.0,
                is_local: false,
                transport_type: "wifi".to_string(),
            },
        ];

        // 14 GB model fits in PC (16GB) + USB (8GB) = 24GB. Wi-Fi tablet should be gated!
        let plan = ClusterCoordinator::plan_distribution(nodes, 14000.0, 32).unwrap();
        assert_eq!(plan.allocations.len(), 1); // Fits completely in RTX 4090
        assert_eq!(plan.allocations[0].node_id, "local");
    }

    #[test]
    fn test_recruit_wifi_when_model_exceeds_wired() {
        let nodes = vec![
            ClusterNode {
                id: "local".to_string(),
                name: "PC".to_string(),
                endpoint: "127.0.0.1:50051".to_string(),
                capacity_mb: 8000.0,
                bandwidth_gbps: 100.0,
                latency_ms: 0.0,
                is_local: true,
                transport_type: "unknown".to_string(),
            },
            ClusterNode {
                id: "wifi-laptop".to_string(),
                name: "Laptop (Wi-Fi)".to_string(),
                endpoint: "192.168.1.120:50052".to_string(),
                capacity_mb: 16000.0,
                bandwidth_gbps: 60.0,
                latency_ms: 18.0,
                is_local: false,
                transport_type: "wifi".to_string(),
            },
        ];

        // 18 GB model exceeds local PC (8GB), must recruit Wi-Fi laptop
        let plan = ClusterCoordinator::plan_distribution(nodes, 18000.0, 40).unwrap();
        assert_eq!(plan.allocations.len(), 2);
    }
}

