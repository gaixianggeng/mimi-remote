//! `model/list` 使用当前 Claude CLI 的 SDK 初始化目录。

use std::collections::HashSet;
use std::sync::Arc;

use alleycat_codex_proto as p;
use serde_json::json;

use crate::pool::model_catalog::ClaudeModelInfo;
use crate::state::ConnectionState;

pub const MODEL_PROVIDER: &str = "anthropic";

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
    state: &Arc<ConnectionState>,
    _params: p::ModelListParams,
) -> p::ModelListResponse {
    let data = match state.claude_pool().discover_models().await {
        Ok(models) => catalog_models(models),
        // 不把 CLI 初始化响应或账号信息写入错误日志；失败只使用无版本的 alias。
        Err(_) => Vec::new(),
    };
    p::ModelListResponse {
        data: if data.is_empty() {
            fallback_models()
        } else {
            data
        },
        next_cursor: None,
    }
}

/// 把 CLI 目录整理成与 Claude 桌面版一致的主列表：每个模型家族只留最新版本，
/// `default` 这类别名不单独占一行，而是把“默认”标记转移到它解析出的那个模型上。
/// 其余条目（旧版本、与默认同解析的别名）仍然返回，但标 `hidden`，客户端不展示。
///
/// CLI 目录同时包含 `default`、`opus[1m]`、`claude-fable-5-1[1m]`、`claude-fable-5[1m]`
/// 等条目，直接铺开会出现“Default”和“Opus”两行同一个模型、以及新旧两个 Fable。
fn catalog_models(models: Vec<ClaudeModelInfo>) -> Vec<p::Model> {
    let ordered = order_strongest_first(models);
    // `default` 解析出的真实模型：它对应的那一行才是“默认选中”。
    let default_resolved = ordered
        .iter()
        .find(|info| info.value == "default")
        .map(resolved_model_id)
        .map(str::to_string);

    let mut seen_families: HashSet<String> = HashSet::new();
    let mut default_marked = false;
    let mut out = Vec::new();
    for info in &ordered {
        // 别名行自己不进主列表；默认标记会落到它解析出的模型上。
        if info.value == "default" {
            continue;
        }
        let resolved = resolved_model_id(info).to_string();
        // 家族未知（第三方/未来命名）时按条目自身分组：不确定的东西不折叠。
        let family = model_family(&resolved).unwrap_or_else(|| format!("id:{resolved}"));
        // ordered 已按“家族内版本降序”排好，所以每个家族第一次出现的就是最新版。
        let primary = seen_families.insert(family);
        let is_default =
            !default_marked && primary && default_resolved.as_deref() == Some(resolved.as_str());
        if is_default {
            default_marked = true;
        }
        let Some(mut model) = convert_model(info.clone()) else {
            continue;
        };
        model.hidden = !primary;
        model.is_default = is_default;
        out.push(model);
    }
    // 默认解析不到任何可见行（例如 CLI 只给了别名）时保留别名行，避免没有默认项。
    if !default_marked
        && let Some(info) = ordered.iter().find(|info| info.value == "default")
        && let Some(mut model) = convert_model(info.clone())
    {
        model.is_default = true;
        out.insert(0, model);
    }
    out
}

/// CLI 解析出的真实模型 ID；没有就退回发给 CLI 的 value。
fn resolved_model_id(info: &ClaudeModelInfo) -> &str {
    info.resolved_model
        .as_deref()
        .map(str::trim)
        .filter(|id| !id.is_empty())
        .unwrap_or(info.value.as_str())
}

/// `claude-fable-5-1[1m]` → `fable`。识别不出家族时返回 None。
fn model_family(id: &str) -> Option<String> {
    let base = id.split_once('[').map_or(id, |(base, _)| base);
    let base = base.strip_prefix("claude-")?;
    let family = base.split('-').next()?;
    if family.is_empty() || family.chars().all(|ch| ch.is_ascii_digit()) {
        return None;
    }
    Some(family.to_ascii_lowercase())
}

fn convert_model(info: ClaudeModelInfo) -> Option<p::Model> {
    if info.value.trim().is_empty() {
        return None;
    }
    let efforts = if info.supports_effort == Some(false) {
        Vec::new()
    } else if let Some(levels) = &info.supported_effort_levels {
        levels
            .iter()
            .filter_map(|level| serde_json::from_value(json!(level)).ok())
            .collect()
    } else if info.supports_effort == Some(true) {
        // 旧 CLI 只声明支持 effort 时保留默认 high，不猜测它支持 Max 等额外档位。
        vec![p::ReasoningEffort::High]
    } else {
        Vec::new()
    };
    let title = if info.value == "default" {
        info.display_name.clone()
    } else {
        info.resolved_model
            .as_deref()
            .or(Some(info.value.as_str()))
            .and_then(model_version_title)
            .unwrap_or_else(|| info.display_name.clone())
    };
    // is_default / hidden 由 catalog_models 统一决定。
    let mut model = build_model(&info.value, &title, &info.description, false, efforts);
    if model.display_name.trim().is_empty() {
        model.display_name = info.value;
    }
    Some(model)
}

// resolvedModel 是 CLI 解析出的实际版本。只格式化常规 Claude ID；第三方/未来未知
// 命名仍使用 CLI 的 displayName，不按模型家族维护版本表，也不修改发送给 CLI 的 value。
fn model_version_title(id: &str) -> Option<String> {
    let (id, context) = match id.split_once('[') {
        Some((id, context)) => (id, Some(context.strip_suffix(']')?)),
        None => (id, None),
    };
    let parts: Vec<_> = id.strip_prefix("claude-")?.split('-').collect();
    let version_start = parts
        .iter()
        .position(|part| part.chars().all(|ch| ch.is_ascii_digit()))?;
    if version_start == 0 {
        return None;
    }
    let mut version = Vec::new();
    for part in &parts[version_start..] {
        if part.len() == 8 && part.chars().all(|ch| ch.is_ascii_digit()) {
            break;
        }
        if part.is_empty() || !part.chars().all(|ch| ch.is_ascii_digit()) {
            return None;
        }
        version.push(*part);
    }
    if version.is_empty() {
        return None;
    }
    let name = parts[..version_start]
        .iter()
        .map(|part| {
            let mut chars = part.chars();
            chars
                .next()
                .map(|first| first.to_uppercase().to_string() + chars.as_str())
        })
        .collect::<Option<Vec<_>>>()?
        .join(" ");
    let mut title = format!("Claude {name} {}", version.join("."));
    if let Some(context) = context {
        title.push_str(&format!(" ({})", context.to_uppercase()));
    }
    Some(title)
}

/// 列表顺序：Default 固定第一，其余按家族（Fable > Opus > Sonnet > Haiku）再按版本号
/// 降序，同版本优先 1M 上下文。CLI 自己的顺序把 Opus 排在 Fable 前面，用户要的是
/// 最强模型在最上面。未知家族按 CLI 原顺序排在最后。
fn order_strongest_first(mut models: Vec<ClaudeModelInfo>) -> Vec<ClaudeModelInfo> {
    models.sort_by_key(catalog_rank);
    models
}

fn catalog_rank(info: &ClaudeModelInfo) -> (u8, u8, [std::cmp::Reverse<u32>; 4], u8) {
    if info.value == "default" {
        return (0, 0, [std::cmp::Reverse(0); 4], 0);
    }
    let id = info
        .resolved_model
        .as_deref()
        .unwrap_or(info.value.as_str());
    let (base, context) = match id.split_once('[') {
        Some((base, context)) => (base, context.trim_end_matches(']')),
        None => (id, ""),
    };
    let base = base.strip_prefix("claude-").unwrap_or(base);
    let family = base.split('-').next().unwrap_or("").to_ascii_lowercase();
    let family_rank = match family.as_str() {
        "fable" => 1,
        "opus" => 2,
        "sonnet" => 3,
        "haiku" => 4,
        _ => 5,
    };
    let mut version = [std::cmp::Reverse(0u32); 4];
    for (slot, part) in base
        .split('-')
        .skip(1)
        .take_while(|part| {
            !part.is_empty() && part.len() < 8 && part.chars().all(|ch| ch.is_ascii_digit())
        })
        .take(4)
        .enumerate()
    {
        version[slot] = std::cmp::Reverse(part.parse().unwrap_or(0));
    }
    let context_rank = if context.eq_ignore_ascii_case("1m") {
        0
    } else {
        1
    };
    (1, family_rank, version, context_rank)
}

fn fallback_models() -> Vec<p::Model> {
    // CLI 不支持目录查询或暂不可用时，基础 alias 仍由 CLI 自己解析，名称不承诺版本。
    [
        ("opus", "Claude Opus"),
        ("sonnet", "Claude Sonnet"),
        ("haiku", "Claude Haiku"),
    ]
    .into_iter()
    .map(|(id, title)| {
        build_model(
            id,
            title,
            "Claude CLI alias; model catalog unavailable.",
            id == "opus",
            if id == "haiku" {
                Vec::new()
            } else {
                vec![
                    p::ReasoningEffort::Medium,
                    p::ReasoningEffort::High,
                    p::ReasoningEffort::XHigh,
                    p::ReasoningEffort::Max,
                ]
            },
        )
    })
    .collect()
}

fn build_model(
    model_id: &str,
    display_name: &str,
    description: &str,
    is_default: bool,
    efforts: Vec<p::ReasoningEffort>,
) -> p::Model {
    let default_reasoning_effort = if efforts.contains(&p::ReasoningEffort::High) {
        p::ReasoningEffort::High
    } else {
        efforts.first().copied().unwrap_or(p::ReasoningEffort::None)
    };
    p::Model {
        id: model_id.to_string(),
        model: model_id.to_string(),
        upgrade: None,
        upgrade_info: None,
        availability_nux: None,
        display_name: display_name.to_string(),
        description: description.to_string(),
        hidden: false,
        supported_reasoning_efforts: efforts
            .into_iter()
            .map(|effort| p::ReasoningEffortOption {
                reasoning_effort: effort,
                description: String::new(),
            })
            .collect(),
        default_reasoning_effort,
        input_modalities: vec![json!("text"), json!("image")],
        supports_personality: false,
        additional_speed_tiers: Vec::new(),
        service_tiers: vec![p::ModelServiceTier {
            id: "standard".to_string(),
            name: "Standard".to_string(),
            description: "Default bridge service tier".to_string(),
        }],
        is_default,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn future_models_use_cli_ids_versions_and_capabilities() {
        let info = serde_json::from_value(json!({
            "value": "fable", "resolvedModel": "claude-fable-9-2", "displayName": "Fable",
            "description": "Runtime model", "supportsEffort": true,
            "supportedEffortLevels": ["medium", "max", "future-effort"]
        }))
        .unwrap();
        let model = convert_model(info).unwrap();
        assert_eq!(model.id, "fable");
        assert_eq!(model.model, "fable");
        assert_eq!(model.display_name, "Claude Fable 9.2");
        assert_eq!(model.description, "Runtime model");
        assert_eq!(
            model
                .supported_reasoning_efforts
                .iter()
                .map(|e| e.reasoning_effort)
                .collect::<Vec<_>>(),
            vec![p::ReasoningEffort::Medium, p::ReasoningEffort::Max]
        );
        assert_eq!(model.default_reasoning_effort, p::ReasoningEffort::Medium);
    }

    #[test]
    fn defaults_unknown_names_and_missing_capabilities_are_not_invented() {
        let info = serde_json::from_value(json!({
            "value": "default", "resolvedModel": "vendor:new", "displayName": "Vendor Latest",
            "description": "Chosen by CLI"
        }))
        .unwrap();
        // convert_model 只做字段翻译；is_default 由 catalog_models 统一决定。
        let model = convert_model(info).unwrap();
        assert!(!model.is_default);
        assert_eq!(model.display_name, "Vendor Latest");
        assert!(model.supported_reasoning_efforts.is_empty());
        assert_eq!(model.default_reasoning_effort, p::ReasoningEffort::None);
        assert_eq!(
            model_version_title("claude-haiku-4-5-20251001").as_deref(),
            Some("Claude Haiku 4.5")
        );
        assert_eq!(
            model_version_title("claude-opus-9[1m]").as_deref(),
            Some("Claude Opus 9 (1M)")
        );
    }

    #[test]
    fn fallback_only_contains_unversioned_cli_aliases() {
        let models = fallback_models();
        assert_eq!(
            models.iter().map(|m| m.model.as_str()).collect::<Vec<_>>(),
            vec!["opus", "sonnet", "haiku"]
        );
        assert_eq!(
            models
                .iter()
                .map(|m| m.display_name.as_str())
                .collect::<Vec<_>>(),
            vec!["Claude Opus", "Claude Sonnet", "Claude Haiku"]
        );
        assert!(models[0].is_default);
    }
}

#[cfg(test)]
mod ordering_tests {
    use super::*;

    fn info(value: &str, resolved: Option<&str>) -> ClaudeModelInfo {
        ClaudeModelInfo {
            value: value.to_string(),
            display_name: value.to_string(),
            resolved_model: resolved.map(str::to_string),
            description: String::new(),
            supports_effort: None,
            supported_effort_levels: None,
        }
    }

    #[test]
    fn strongest_model_first_after_default() {
        // CLI 的原顺序：Default、Opus、Fable 5、Fable 5.1、Sonnet、Haiku。
        let cli_order = vec![
            info("default", None),
            info("opus[1m]", Some("claude-opus-5[1m]")),
            info("claude-fable-5[1m]", Some("claude-fable-5[1m]")),
            info("claude-fable-5-1", Some("claude-fable-5-1")),
            info("sonnet", Some("claude-sonnet-5")),
            info("haiku", Some("claude-haiku-4-5-20251001")),
        ];
        let ordered: Vec<_> = order_strongest_first(cli_order)
            .into_iter()
            .map(|info| info.value)
            .collect();
        assert_eq!(
            ordered,
            vec![
                "default",
                "claude-fable-5-1",
                "claude-fable-5[1m]",
                "opus[1m]",
                "sonnet",
                "haiku"
            ]
        );
    }

    /// 本机 CLI 2.1.224 的真实目录形状：default + 两个 Fable + Opus 1M + Sonnet + Haiku。
    /// 主列表要和 Claude 桌面版一致：每个家族一行、最新版本，默认落在 CLI 解析出的模型上。
    #[test]
    fn catalog_matches_desktop_primary_list_and_marks_resolved_default() {
        let cli = vec![
            ClaudeModelInfo {
                value: "default".into(),
                display_name: "Default (recommended)".into(),
                resolved_model: Some("claude-opus-5[1m]".into()),
                description: "Opus 5 with 1M context".into(),
                supports_effort: Some(true),
                supported_effort_levels: None,
            },
            info("opus[1m]", Some("claude-opus-5[1m]")),
            info("claude-fable-5-1[1m]", Some("claude-fable-5-1")),
            info("claude-fable-5[1m]", Some("claude-fable-5")),
            info("sonnet", Some("claude-sonnet-5")),
            info("haiku", Some("claude-haiku-4-5-20251001")),
        ];
        let models = catalog_models(cli);
        let visible: Vec<_> = models
            .iter()
            .filter(|model| !model.hidden)
            .map(|model| model.id.as_str())
            .collect();
        assert_eq!(
            visible,
            vec!["claude-fable-5-1[1m]", "opus[1m]", "sonnet", "haiku"],
            "主列表每个家族一行、最新版本在前"
        );
        let hidden: Vec<_> = models
            .iter()
            .filter(|model| model.hidden)
            .map(|model| model.id.as_str())
            .collect();
        assert_eq!(hidden, vec!["claude-fable-5[1m]"], "旧版本保留但不展示");
        assert!(
            !models.iter().any(|model| model.id == "default"),
            "default 别名不再单独占一行"
        );
        let default: Vec<_> = models
            .iter()
            .filter(|model| model.is_default)
            .map(|model| model.id.as_str())
            .collect();
        assert_eq!(
            default,
            vec!["opus[1m]"],
            "默认标记落到 default 解析出的那个模型上"
        );
    }

    #[test]
    fn alias_only_catalog_keeps_the_default_row() {
        // CLI 没给出可解析的具体模型时不能没有默认项。
        let models = catalog_models(vec![ClaudeModelInfo {
            value: "default".into(),
            display_name: "Default (recommended)".into(),
            resolved_model: None,
            description: String::new(),
            supports_effort: None,
            supported_effort_levels: None,
        }]);
        assert_eq!(models.len(), 1);
        assert_eq!(models[0].id, "default");
        assert!(models[0].is_default && !models[0].hidden);
    }

    #[test]
    fn unknown_families_stay_visible() {
        let models = catalog_models(vec![
            info("vendor-a", Some("vendor:a-1")),
            info("vendor-b", Some("vendor:b-2")),
            info("sonnet", Some("claude-sonnet-5")),
        ]);
        assert!(
            models.iter().all(|model| !model.hidden),
            "识别不出家族的条目不折叠：{:?}",
            models.iter().map(|m| (&m.id, m.hidden)).collect::<Vec<_>>()
        );
    }

    #[test]
    fn unknown_families_and_aliases_keep_cli_order_at_the_end() {
        let ordered: Vec<_> = order_strongest_first(vec![
            info("mystery-model", None),
            info("opus", None),
            info("claude-opus-5[1m]", Some("claude-opus-5[1m]")),
            info("claude-opus-5", Some("claude-opus-5")),
            info("another-mystery", None),
        ])
        .into_iter()
        .map(|info| info.value)
        .collect();
        // 同版本 1M 优先；无版本别名排在有版本的同家族之后；未知家族按原顺序垫底。
        assert_eq!(
            ordered,
            vec![
                "claude-opus-5[1m]",
                "claude-opus-5",
                "opus",
                "mystery-model",
                "another-mystery"
            ]
        );
    }
}
