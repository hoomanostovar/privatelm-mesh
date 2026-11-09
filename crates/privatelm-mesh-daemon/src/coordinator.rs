//! Heterogeneous Cluster Coordinator & Layer Placement Engine
//!
//! Formulates optimal layer distribution plans across heterogeneous nodes
//! (Windows PC, Apple Silicon Mac, Linux Server, Android/iOS) based on:
//! 1. Memory capacity (VRAM / RAM)
//! 2. Memory bandwidth (GB/s read throughput)
//! 3. Network latency & interconnect quality

use serde::{Deserialize, Serialize};
use tracing::info;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClusterNode {
    pub id: String,
    pub name: String,
    pub endpoint: String,
    pub capacity_mb: f64,
    pub bandwidth_gbps: f64,
    pub latency_ms: f64,
    pub is_local: bool,
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
    /// - Network latency acts as a dampener (slow network links receive fewer or zero layers).
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

        // Calculate node score: Bandwidth / (1.0 + Latency penalty)
        // Local node has 0 latency penalty.
        let mut scored_nodes: Vec<(ClusterNode, f64)> = nodes
            .into_iter()
            .map(|node| {
                let latency_penalty = if node.is_local { 0.0 } else { (node.latency_ms / 15.0).max(0.1) };
                let score = node.bandwidth_gbps / (1.0 + latency_penalty);
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
            expected_tokens_per_sec: 12.5, // Estimation baseline
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

