//! `model/list`.
//!
//! Claude has no introspection API for available models, so the bridge ships
//! a hand-curated list. Four concrete model ids (fable plus the latest
//! opus/sonnet/haiku) and the three established short aliases
//! (`opus`/`sonnet`/`haiku`) the `claude` CLI accepts via `--model`. Fable uses
//! its full id so the list also works with older CLI builds that predate its alias.
//!
//! Default is opus — the remote app defaults to the most capable model for
//! agentic coding; the picker still lets the user drop to sonnet/haiku.

use std::sync::Arc;

use alleycat_codex_proto as p;
use serde_json::json;

use crate::state::ConnectionState;

pub const MODEL_PROVIDER: &str = "anthropic";

pub const FABLE_MODEL: &str = "claude-fable-5-1";
pub const OPUS_MODEL: &str = "claude-opus-5";
pub const SONNET_MODEL: &str = "claude-sonnet-4-6";
pub const HAIKU_MODEL: &str = "claude-haiku-4-5-20251001";

pub fn normalize_claude_model_id(model: &str) -> String {
    let model = model.trim();
    model
        .strip_prefix(&format!("{MODEL_PROVIDER}/"))
        .unwrap_or(model)
        .to_string()
}

pub fn normalize_claude_model(model: Option<String>) -> Option<String> {
    model.map(|value| normalize_claude_model_id(&value))
}

pub async fn handle_model_list(
    _state: &Arc<ConnectionState>,
    _params: p::ModelListParams,
) -> p::ModelListResponse {
    let data = vec![
        // Concrete model ids first.
        build_model(
            FABLE_MODEL,
            "Claude Fable 5.1",
            "Anthropic's most capable generally available model for the hardest, longest-running agentic work.",
            false,
            p::ReasoningEffort::High,
            true,
        ),
        build_model(
            OPUS_MODEL,
            "Claude Opus 5",
            "Anthropic's most capable model. Best for hard reasoning, deep refactors, multi-step planning.",
            true,
            p::ReasoningEffort::High,
            true,
        ),
        build_model(
            SONNET_MODEL,
            "Claude Sonnet 4.6",
            "Balanced model for everyday coding work — fast, capable, lower cost than Opus.",
            false,
            p::ReasoningEffort::High,
            true,
        ),
        build_model(
            HAIKU_MODEL,
            "Claude Haiku 4.5",
            "Lightest, fastest model. Best for quick edits, small tasks, low-latency interactions.",
            false,
            p::ReasoningEffort::None,
            false,
        ),
        // Short aliases the `claude` CLI accepts directly.
        build_model(
            "opus",
            "Claude Opus (alias)",
            "Alias resolved by the claude CLI to the latest Opus revision.",
            false,
            p::ReasoningEffort::High,
            true,
        ),
        build_model(
            "sonnet",
            "Claude Sonnet (alias)",
            "Alias resolved by the claude CLI to the latest Sonnet revision.",
            false,
            p::ReasoningEffort::High,
            true,
        ),
        build_model(
            "haiku",
            "Claude Haiku (alias)",
            "Alias resolved by the claude CLI to the latest Haiku revision.",
            false,
            p::ReasoningEffort::None,
            false,
        ),
    ];
    p::ModelListResponse {
        data,
        next_cursor: None,
    }
}

fn build_model(
    model_id: &str,
    display_name: &str,
    description: &str,
    is_default: bool,
    default_effort: p::ReasoningEffort,
    supports_native_effort: bool,
) -> p::Model {
    p::Model {
        id: model_id.to_string(),
        model: model_id.to_string(),
        upgrade: None,
        upgrade_info: None,
        availability_nux: None,
        display_name: display_name.to_string(),
        description: description.to_string(),
        hidden: false,
        supported_reasoning_efforts: if supports_native_effort {
            reasoning_options()
        } else {
            Vec::new()
        },
        default_reasoning_effort: default_effort,
        input_modalities: vec![json!("text"), json!("image")],
        supports_personality: false,
        additional_speed_tiers: Vec::new(),
        service_tiers: standard_service_tiers(),
        is_default,
    }
}

fn standard_service_tiers() -> Vec<p::ModelServiceTier> {
    vec![p::ModelServiceTier {
        id: "standard".to_string(),
        name: "Standard".to_string(),
        description: "Default bridge service tier".to_string(),
    }]
}

fn reasoning_options() -> Vec<p::ReasoningEffortOption> {
    vec![
        p::ReasoningEffortOption {
            reasoning_effort: p::ReasoningEffort::Medium,
            description: "Balanced native Claude effort".to_string(),
        },
        p::ReasoningEffortOption {
            reasoning_effort: p::ReasoningEffort::High,
            description: "High native Claude effort (default)".to_string(),
        },
        p::ReasoningEffortOption {
            reasoning_effort: p::ReasoningEffort::XHigh,
            description: "Extended native Claude effort".to_string(),
        },
        p::ReasoningEffortOption {
            reasoning_effort: p::ReasoningEffort::Max,
            description: "Maximum native Claude effort".to_string(),
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::index::ClaudeSessionRef;
    use crate::pool::ClaudePool;
    use crate::state::{ConnectionState, ThreadDefaults};
    use std::path::PathBuf;

    struct NoopIndex;

    #[async_trait::async_trait]
    impl alleycat_bridge_core::ThreadIndexHandle<ClaudeSessionRef> for NoopIndex {
        async fn lookup(&self, _: &str) -> Option<crate::state::IndexEntry> {
            None
        }
        async fn insert(&self, _: crate::state::IndexEntry) -> anyhow::Result<()> {
            Ok(())
        }
        async fn set_archived(&self, _: &str, _: bool) -> anyhow::Result<bool> {
            Ok(false)
        }
        async fn set_name(&self, _: &str, _: Option<String>) -> anyhow::Result<bool> {
            Ok(false)
        }
        async fn update_preview_and_updated_at(
            &self,
            _: &str,
            _: String,
            _: chrono::DateTime<chrono::Utc>,
        ) -> anyhow::Result<()> {
            Ok(())
        }
        async fn list(
            &self,
            _: &crate::state::ListFilter,
            _: crate::state::ListSort,
            _: Option<&str>,
            _: Option<u32>,
        ) -> anyhow::Result<crate::state::ListPage<ClaudeSessionRef>> {
            Ok(crate::state::ListPage::<ClaudeSessionRef> {
                data: Vec::new(),
                next_cursor: None,
            })
        }
        async fn loaded_thread_ids(&self) -> Vec<String> {
            Vec::new()
        }
    }

    fn dummy_state() -> Arc<ConnectionState> {
        let (state, _rx) = ConnectionState::for_test(
            Arc::new(ClaudePool::new(PathBuf::from("/usr/bin/false"))),
            Arc::new(NoopIndex),
            ThreadDefaults::default(),
        );
        state
    }

    #[tokio::test]
    async fn lists_four_concrete_models_plus_established_aliases_with_opus_default() {
        let state = dummy_state();
        let resp = handle_model_list(&state, p::ModelListParams::default()).await;
        assert_eq!(resp.data.len(), 7);

        let by_id: std::collections::HashMap<_, _> =
            resp.data.iter().map(|m| (m.model.as_str(), m)).collect();

        // 同时锁定显示名和真正传给 CLI 的 ID，避免只升级文案。
        let fable = by_id["claude-fable-5-1"];
        assert_eq!(fable.id, "claude-fable-5-1");
        assert_eq!(fable.display_name, "Claude Fable 5.1");
        assert!(!by_id.contains_key("claude-fable-5"));
        assert!(by_id.contains_key(OPUS_MODEL));
        assert!(by_id.contains_key(SONNET_MODEL));
        assert!(by_id.contains_key(HAIKU_MODEL));
        assert!(by_id.contains_key("opus"));
        assert!(by_id.contains_key("sonnet"));
        assert!(by_id.contains_key("haiku"));

        let opus = by_id[OPUS_MODEL];
        assert!(opus.is_default);
        assert_eq!(opus.id, OPUS_MODEL);
        assert!(matches!(
            opus.default_reasoning_effort,
            p::ReasoningEffort::High
        ));
        assert_eq!(opus.supported_reasoning_efforts.len(), 4);
        assert_eq!(
            opus.supported_reasoning_efforts
                .iter()
                .map(|option| option.reasoning_effort)
                .collect::<Vec<_>>(),
            vec![
                p::ReasoningEffort::Medium,
                p::ReasoningEffort::High,
                p::ReasoningEffort::XHigh,
                p::ReasoningEffort::Max,
            ]
        );
        assert!(
            by_id[HAIKU_MODEL].supported_reasoning_efforts.is_empty(),
            "Haiku 4.5 不支持 Claude 原生 effort"
        );
        assert!(matches!(
            by_id[HAIKU_MODEL].default_reasoning_effort,
            p::ReasoningEffort::None
        ));

        // The other concrete models are no longer the default.
        assert!(!by_id[SONNET_MODEL].is_default);

        // Only one default across the entire list.
        let defaults: Vec<_> = resp.data.iter().filter(|m| m.is_default).collect();
        assert_eq!(defaults.len(), 1);
    }

    #[tokio::test]
    async fn ids_are_plain_claude_cli_model_values() {
        let state = dummy_state();
        let resp = handle_model_list(&state, p::ModelListParams::default()).await;
        for m in &resp.data {
            assert!(
                !m.id.contains('/'),
                "id {} should be a plain claude CLI model value, not provider-prefixed",
                m.id
            );
        }
    }
}
