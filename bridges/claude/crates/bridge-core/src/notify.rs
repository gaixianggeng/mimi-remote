use std::sync::Arc;
use std::time::Duration;

use serde_json::Value;
use tokio::sync::oneshot;

use crate::envelope::{
    JsonRpcMessage, JsonRpcNotification, JsonRpcRequest, JsonRpcResponse, JsonRpcVersion, RequestId,
};
use crate::session::Session;
use crate::state::ServerRequestError;

/// Thin façade over [`Session`] that handlers use to emit outbound traffic.
/// Every send routes through `session.enqueue`, which appends to the replay
/// ring and forwards to the live drainer if attached.
#[derive(Clone)]
pub struct NotificationSender {
    session: Arc<Session>,
}

impl NotificationSender {
    pub fn new(session: Arc<Session>) -> Self {
        Self { session }
    }

    pub fn session(&self) -> &Arc<Session> {
        &self.session
    }

    pub fn send_notification(
        &self,
        method: impl Into<String>,
        params: impl serde::Serialize,
    ) -> anyhow::Result<()> {
        let method = method.into();
        if !self.session.should_emit(&method) {
            return Ok(());
        }
        let frame = JsonRpcMessage::Notification(JsonRpcNotification {
            jsonrpc: JsonRpcVersion,
            method,
            params: Some(serde_json::to_value(params)?),
        });
        self.session.enqueue(serde_json::to_value(&frame)?);
        Ok(())
    }

    pub fn send_message(&self, message: JsonRpcMessage) -> anyhow::Result<()> {
        self.session.enqueue(serde_json::to_value(&message)?);
        Ok(())
    }

    /// Answer a client request that arrived on attachment `generation`.
    /// Returns whether the response was accepted for the attachment that asked
    /// for it. `false` means that stream has since been replaced and the answer
    /// was dropped rather than handed to its successor.
    pub fn send_response(
        &self,
        response: JsonRpcResponse,
        generation: u64,
    ) -> anyhow::Result<bool> {
        let frame = serde_json::to_value(JsonRpcMessage::Response(response))?;
        Ok(self
            .session
            .enqueue_for_generation(frame, generation)
            .is_some())
    }

    /// Issue a server→client request and await the response, with a per-call
    /// timeout. The request id is minted by the session, the pending oneshot
    /// is parked in the session's pending table, and the params are stored in
    /// the session's outstanding-requests table so a reattach within the
    /// pending grace window can replay the request to the new client.
    pub async fn request(
        &self,
        method: impl Into<String>,
        params: impl serde::Serialize,
        timeout: Duration,
    ) -> Result<Value, ServerRequestError> {
        let method = method.into();
        let params_value = serde_json::to_value(&params).map_err(|err| {
            ServerRequestError::Rpc(crate::JsonRpcError::internal(err.to_string()))
        })?;
        let id = self.session.next_request_id();
        let (tx, rx) = oneshot::channel();
        self.session
            .register_pending(id.clone(), method.clone(), params_value.clone(), tx);
        let frame = JsonRpcMessage::Request(JsonRpcRequest {
            jsonrpc: JsonRpcVersion,
            id: RequestId::String(id.clone()),
            method,
            params: Some(params_value),
        });
        let frame_value = serde_json::to_value(&frame).map_err(|err| {
            ServerRequestError::Rpc(crate::JsonRpcError::internal(err.to_string()))
        })?;
        self.session.enqueue(frame_value);
        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err(ServerRequestError::ConnectionClosed),
            Err(_) => {
                self.session.forget_pending(&id);
                Err(ServerRequestError::TimedOut)
            }
        }
    }

    pub async fn resolve_response(&self, response: JsonRpcResponse) -> bool {
        let result = match response.error {
            Some(error) => Err(ServerRequestError::Rpc(error)),
            None => Ok(response.result.unwrap_or(Value::Null)),
        };
        self.session
            .resolve_pending(&response.id.to_string(), result)
    }

    pub async fn cancel_all(&self) {
        self.session.cancel_all_pending();
    }
}
