//! `alleycat-claude-bridge` — codex app-server façade over `claude -p`.

pub mod approval;
pub mod bridge;
pub mod foreign_session;
pub mod handlers;
pub mod index;
mod oauth_usage;
pub mod pool;
pub mod server;
pub mod state;
pub mod translate;

pub use bridge::{ClaudeBridge, ClaudeBridgeBuilder};
pub use index::ClaudeSessionRef;

// Test-helper re-export. The anonymous-session `run_connection` shim is used
// by `tests/smoke_in_process.rs`; production traffic uses
// `ClaudeBridge::builder()` plus `bridge_core::serve_stream_with_session`.
pub use server::run_connection;
