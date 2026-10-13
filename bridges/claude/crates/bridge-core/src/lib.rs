pub mod codex_resolver;
pub mod envelope;
pub mod framing;
pub mod git_info;
pub mod launch_environment;
pub mod launcher;
pub mod notify;
pub mod pool;
pub mod server;
pub mod session;
pub mod state;
#[cfg(all(test, unix))]
mod test_support;
pub mod thread_index;

pub use envelope::{
    InboundMessage, JsonRpcError, JsonRpcMessage, JsonRpcNotification, JsonRpcRequest,
    JsonRpcResponse, JsonRpcVersion, RequestId, error_codes,
};
pub use git_info::git_info_for_cwd;
pub use launch_environment::{
    LaunchEnvironment, LaunchEnvironmentPolicy, LaunchEnvironmentResolver, UserEnvironmentLauncher,
};
pub use launcher::{
    ChildProcess, ChildStderr, ChildStdin, ChildStdout, LocalLauncher, ProcessLauncher,
    ProcessRole, ProcessSpec, StdioMode,
};
pub use notify::NotificationSender;
pub use server::{
    ATTACH_METHOD, ATTACHED_METHOD, Bridge, Conn, TcpServerOptions, bind_loopback_tcp, serve_stdio,
    serve_stream, serve_stream_attached, serve_stream_with_session, serve_tcp, serve_tcp_listener,
};
#[cfg(unix)]
pub use server::{ServerOptions, serve_unix};
pub use session::{
    AttachKind, AttachOutcome, AttachReservation, Session, SessionRegistry, SessionRegistryConfig,
    TurnGuard,
};
pub use thread_index::{
    DEFAULT_LIST_LIMIT, Hydrator, IndexEntry, ListFilter, ListPage, ListSort, MAX_LIST_LIMIT,
    ThreadIndex, ThreadIndexHandle, encode_backwards_cursor, resolve_list_limit,
};
