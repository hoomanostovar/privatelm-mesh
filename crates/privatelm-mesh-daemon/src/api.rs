//! Local Control & Telemetry API
//!
//! Exposes an Axum HTTP & WebSocket service on localhost (127.0.0.1:50053)
//! allowing the Flutter GUI client to monitor cluster status, stream metrics,
//! and orchestrate distributed loading without process coupling.

use crate::coordinator::{ClusterCoordinator, ClusterNode, ClusterPlan};
use crate::discovery::{DiscoveryManager, WorkerMetadata};
use crate::worker::{WorkerStatus, WorkerSupervisor};
use axum::{
    extract::State,
    http::StatusCode,
    response::IntoResponse,
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use std::net::SocketAddr;
use std::sync::Arc;
use tower_http::cors::{Any, CorsLayer};
use tracing::info;

#[derive(Clone)]
pub struct AppState {
    pub supervisor: Arc<WorkerSupervisor>,
    pub discovery: Arc<DiscoveryManager>,
}

pub struct ApiServer;

impl ApiServer {
    pub async fn run(state: AppState, port: u16) -> anyhow::Result<()> {
        let cors = CorsLayer::new()
            .allow_origin(Any)
            .allow_methods(Any)
            .allow_headers(Any);

        let app = Router::new()
            .route("/status", get(get_status))
            .route("/workers", get(list_workers))
            .route("/worker/start", post(start_worker))
            .route("/worker/stop", post(stop_worker))
            .route("/plan", post(create_plan))
            .layer(cors)
            .with_state(state);

        let addr = SocketAddr::from(([127, 0, 0, 1], port));
        info!(addr = %addr, "Control API listening");

        let listener = tokio::net::TcpListener::bind(addr).await?;
        axum::serve(listener, app).await?;

        Ok(())
    }
}

async fn get_status(State(state): State<AppState>) -> Json<WorkerStatus> {
    Json(state.supervisor.get_status().await)
}

async fn list_workers(State(state): State<AppState>) -> Json<Vec<WorkerMetadata>> {
    Json(state.discovery.get_workers().await)
}

async fn start_worker(State(state): State<AppState>) -> impl IntoResponse {
    let bw = crate::bench::measure_memory_bandwidth(4);
    match state.supervisor.start(bw).await {
        Ok(_) => StatusCode::OK.into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

async fn stop_worker(State(state): State<AppState>) -> impl IntoResponse {
    match state.supervisor.stop().await {
        Ok(_) => StatusCode::OK.into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

#[derive(Deserialize)]
struct PlanRequest {
    nodes: Vec<ClusterNode>,
    model_size_mb: f64,
    total_layers: usize,
}

async fn create_plan(
    Json(payload): Json<PlanRequest>,
) -> Result<Json<ClusterPlan>, (StatusCode, String)> {
    ClusterCoordinator::plan_distribution(payload.nodes, payload.model_size_mb, payload.total_layers)
        .map(Json)
        .map_err(|err| (StatusCode::BAD_REQUEST, err))
}
