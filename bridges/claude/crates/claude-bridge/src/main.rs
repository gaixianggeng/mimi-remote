//! `alleycat-claude-bridge` binary entry point.
//!
//! Defaults to stdio. With `--socket <path>` (or `ALLEYCAT_BRIDGE_SOCKET`),
//! listens on a Unix socket. With `--tcp-listen <loopback-ip>:<port>`, listens
//! on loopback TCP on every platform. The bridge is constructed via
//! [`ClaudeBridgeBuilder`] and served through `bridge_core::serve_*` helpers.

use std::ffi::OsString;
use std::net::SocketAddr;
use std::path::PathBuf;

use anyhow::{Context, Result};

#[cfg(unix)]
use alleycat_bridge_core::{ServerOptions, serve_unix};
use alleycat_bridge_core::{SessionRegistryConfig, TcpServerOptions, serve_stdio, serve_tcp};
use alleycat_claude_bridge::ClaudeBridge;

#[tokio::main]
async fn main() -> Result<()> {
    if version_requested() {
        println!("alleycat-claude-bridge {}", env!("CARGO_PKG_VERSION"));
        return Ok(());
    }
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .with_writer(std::io::stderr)
        .init();
    tracing::info!(
        version = env!("CARGO_PKG_VERSION"),
        "alleycat-claude-bridge starting"
    );

    // Parse and validate the transport before starting any child-process
    // discovery or other bridge initialization.
    let transport = transport_arg()?;
    let bridge = ClaudeBridge::builder().from_env().build().await?;

    match transport {
        Transport::Unix(path) => {
            #[cfg(unix)]
            {
                serve_unix(
                    bridge,
                    ServerOptions {
                        socket_path: path,
                        unlink_stale: true,
                        agent: "claude",
                        registry: SessionRegistryConfig::default(),
                    },
                )
                .await
            }
            #[cfg(not(unix))]
            {
                let _ = bridge;
                anyhow::bail!(
                    "Unix socket transport is not supported on Windows: {}",
                    path.display()
                );
            }
        }
        Transport::Tcp(addr) => {
            serve_tcp(
                bridge,
                TcpServerOptions {
                    listen_addr: addr,
                    agent: "claude",
                    registry: SessionRegistryConfig::default(),
                },
            )
            .await
        }
        Transport::Stdio => serve_stdio(bridge).await,
    }
}

fn version_requested() -> bool {
    std::env::args_os()
        .skip(1)
        .any(|arg| arg == "--version" || arg == "-V")
}

#[derive(Debug, PartialEq, Eq)]
enum Transport {
    Stdio,
    Unix(PathBuf),
    Tcp(SocketAddr),
}

fn transport_arg() -> Result<Transport> {
    transport_arg_from(std::env::args_os().skip(1), || {
        std::env::var_os("ALLEYCAT_BRIDGE_SOCKET")
    })
}

fn transport_arg_from<I, F>(args: I, socket_env: F) -> Result<Transport>
where
    I: IntoIterator<Item = OsString>,
    F: FnOnce() -> Option<OsString>,
{
    let mut args = args.into_iter();
    let mut selected = None;
    while let Some(arg) = args.next() {
        if arg == "--socket" || arg == "--listen" {
            let path = args.next().context("--socket requires a filesystem path")?;
            anyhow::ensure!(
                selected.is_none(),
                "only one bridge transport may be selected"
            );
            selected = Some(Transport::Unix(PathBuf::from(path)));
        } else if arg == "--tcp-listen" {
            let raw = args
                .next()
                .context("--tcp-listen requires an IP:PORT address")?;
            let raw = raw
                .into_string()
                .map_err(|_| anyhow::anyhow!("--tcp-listen address must be valid Unicode"))?;
            let addr: SocketAddr = raw
                .parse()
                .with_context(|| format!("invalid --tcp-listen address: {raw}"))?;
            anyhow::ensure!(
                addr.ip().is_loopback(),
                "--tcp-listen must use a loopback address, got {addr}"
            );
            anyhow::ensure!(
                selected.is_none(),
                "only one bridge transport may be selected"
            );
            selected = Some(Transport::Tcp(addr));
        }
    }
    if let Some(transport) = selected {
        return Ok(transport);
    }
    Ok(socket_env()
        .map(PathBuf::from)
        .map(Transport::Unix)
        .unwrap_or(Transport::Stdio))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn package_is_the_compatibility_release() {
        assert_eq!(env!("CARGO_PKG_VERSION"), "0.2.8");
    }

    #[test]
    fn parses_loopback_tcp_transport() {
        let transport = transport_arg_from(
            [
                OsString::from("--tcp-listen"),
                OsString::from("127.0.0.1:0"),
            ],
            || None,
        )
        .unwrap();
        assert_eq!(transport, Transport::Tcp("127.0.0.1:0".parse().unwrap()));
    }

    #[test]
    fn rejects_non_loopback_tcp_transport() {
        let error = transport_arg_from(
            [
                OsString::from("--tcp-listen"),
                OsString::from("0.0.0.0:9000"),
            ],
            || None,
        )
        .unwrap_err();
        assert!(error.to_string().contains("loopback"));
    }

    #[test]
    fn rejects_multiple_transports() {
        let error = transport_arg_from(
            [
                OsString::from("--socket"),
                OsString::from("/tmp/bridge.sock"),
                OsString::from("--tcp-listen"),
                OsString::from("127.0.0.1:9000"),
            ],
            || None,
        )
        .unwrap_err();
        assert!(error.to_string().contains("only one"));
    }
}
