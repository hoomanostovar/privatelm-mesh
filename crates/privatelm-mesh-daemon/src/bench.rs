//! Hardware and Network Benchmarking Module
//!
//! Provides accurate measurements of local memory read bandwidth (GB/s)
//! and network round-trip latency to cluster peers. Used by the coordinator
//! to weight layer distribution across heterogeneous nodes.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Instant;
use tracing::info;

/// Measures memory read bandwidth in GB/s using multi-threaded chunked reads.
/// Mimics the memory access pattern during LLM dequantization and matrix multiplication.
pub fn measure_memory_bandwidth(threads: usize) -> f64 {
    let threads = threads.max(1);
    // Allocate 64MB per benchmark pass, shared across threads
    let buffer_size_bytes = 64 * 1024 * 1024;
    let u64_count = buffer_size_bytes / std::mem::size_of::<u64>();
    let data: Arc<Vec<u64>> = Arc::new(vec![1u64; u64_count]);
    let chunk_size = u64_count / threads;

    let passes = 4;
    let checksum = Arc::new(AtomicU64::new(0));

    // Warm-up pass: fault in all pages to ensure memory is physically mapped
    let warm_data = Arc::clone(&data);
    let mut sum: u64 = 0;
    for &val in warm_data.iter().step_by(64) {
        sum = sum.wrapping_add(val);
    }
    std::hint::black_box(sum);

    let start = Instant::now();
    let mut handles = Vec::with_capacity(threads);

    for t in 0..threads {
        let data_ref = Arc::clone(&data);
        let checksum_ref = Arc::clone(&checksum);
        let start_idx = t * chunk_size;
        let end_idx = if t == threads - 1 { u64_count } else { (t + 1) * chunk_size };

        let handle = std::thread::spawn(move || {
            let slice = &data_ref[start_idx..end_idx];
            let mut local_sum = 0u64;

            for _ in 0..passes {
                for chunk in slice.chunks_exact(4) {
                    local_sum = local_sum
                        .wrapping_add(chunk[0])
                        .wrapping_add(chunk[1])
                        .wrapping_add(chunk[2])
                        .wrapping_add(chunk[3]);
                }
            }

            checksum_ref.fetch_add(local_sum, Ordering::Relaxed);
        });
        handles.push(handle);
    }

    for handle in handles {
        let _ = handle.join();
    }

    let elapsed = start.elapsed().as_secs_f64();
    if elapsed <= 0.0 {
        return 0.0;
    }

    let total_bytes_read = (u64_count * std::mem::size_of::<u64>() * passes) as f64;
    let bandwidth_gbps = (total_bytes_read / elapsed) / 1_000_000_000.0;

    info!(
        threads = threads,
        bandwidth_gbps = format!("{:.2} GB/s", bandwidth_gbps),
        "Memory bandwidth benchmark completed"
    );

    bandwidth_gbps
}

/// Probes TCP latency (round-trip time in milliseconds) to a remote worker endpoint.
pub async fn probe_endpoint_latency(endpoint: &str) -> Option<f64> {
    let start = Instant::now();
    match tokio::time::timeout(
        std::time::Duration::from_millis(1500),
        tokio::net::TcpStream::connect(endpoint),
    )
    .await
    {
        Ok(Ok(_stream)) => {
            let rtt_ms = start.elapsed().as_secs_f64() * 1000.0;
            Some(rtt_ms)
        }
        _ => None,
    }
}

