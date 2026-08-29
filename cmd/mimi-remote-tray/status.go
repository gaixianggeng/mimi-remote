package main

import (
	"encoding/json"
	"fmt"
	"math"
	"strings"
	"time"
)

type agentStatus struct {
	Version       string         `json:"version"`
	ServerVersion string         `json:"server_version"`
	Endpoint      string         `json:"endpoint"`
	Projects      int            `json:"projects"`
	ProcessOK     bool           `json:"process_ok"`
	ServiceOK     bool           `json:"service_ok"`
	DoctorOK      bool           `json:"doctor_ok"`
	ProcessError  string         `json:"process_error"`
	ServiceError  string         `json:"service_error"`
	RuntimeStatus *runtimeStatus `json:"runtime_status"`
	NetworkStatus *networkStatus `json:"network_status"`
}

type runtimeStatus struct {
	Refreshing bool           `json:"refreshing"`
	Stale      bool           `json:"stale"`
	Runtimes   []runtimeEntry `json:"runtimes"`
}

type runtimeEntry struct {
	ID         string             `json:"id"`
	Title      string             `json:"title"`
	Enabled    bool               `json:"enabled"`
	State      string             `json:"state"`
	Version    string             `json:"version"`
	Reason     string             `json:"reason"`
	PlanType   string             `json:"plan_type"`
	RateLimits *runtimeRateLimits `json:"rate_limits"`
}

type runtimeRateLimits struct {
	PlanType          string                  `json:"plan_type"`
	ReachedType       string                  `json:"reached_type"`
	Availability      string                  `json:"availability"`
	UnavailableReason string                  `json:"unavailable_reason"`
	Primary           *runtimeRateLimitWindow `json:"primary"`
	Secondary         *runtimeRateLimitWindow `json:"secondary"`
	HasCredits        *bool                   `json:"has_credits"`
	CreditsUnlimited  *bool                   `json:"credits_unlimited"`
	CreditBalance     string                  `json:"credit_balance"`
}

type runtimeRateLimitWindow struct {
	UsedPercent       *float64 `json:"used_percent"`
	WindowDurationMin *int64   `json:"window_duration_mins"`
	ResetsAt          *int64   `json:"resets_at"`
}

type networkStatus struct {
	Mode                string `json:"mode"`
	AllowLAN            bool   `json:"allow_lan"`
	PolicyChecked       bool   `json:"policy_checked"`
	PolicyOK            bool   `json:"policy_ok"`
	FirewallValid       bool   `json:"firewall_valid"`
	InterfaceAlias      string `json:"interface_alias"`
	NetworkCategory     string `json:"network_category"`
	UnsafeRuleCount     int    `json:"unsafe_rule_count"`
	PolicyInspectionErr bool   `json:"policy_inspection_error"`
}

func parseAgentStatus(payload []byte) (agentStatus, error) {
	var status agentStatus
	if err := json.Unmarshal(payload, &status); err != nil {
		return agentStatus{}, fmt.Errorf("解析 agentd 状态失败：%w", err)
	}
	if strings.TrimSpace(status.Version) == "" {
		return agentStatus{}, fmt.Errorf("agentd 状态缺少版本")
	}
	return status, nil
}

func (s agentStatus) lifecycleTitle() string {
	networkPolicyOK := s.NetworkStatus == nil ||
		!s.NetworkStatus.PolicyChecked ||
		s.NetworkStatus.PolicyOK
	switch {
	case s.ServiceOK && s.DoctorOK && networkPolicyOK:
		return "运行正常"
	case s.ProcessOK:
		return "服务需要处理"
	default:
		return "服务已停止"
	}
}

func (s agentStatus) tooltip() string {
	title := "Mimi Remote - " + s.lifecycleTitle()
	if endpoint := strings.TrimSpace(s.Endpoint); endpoint != "" {
		title += " - " + endpoint
	}
	return truncateUTF16Text(title, 127)
}

func (s agentStatus) details() string {
	lines := []string{
		"状态：" + s.lifecycleTitle(),
		"Endpoint：" + fallbackText(s.Endpoint, "尚不可用"),
		fmt.Sprintf("项目：%d", s.Projects),
		"agentd：" + fallbackText(firstNonEmpty(s.ServerVersion, s.Version), "未知"),
	}
	if s.NetworkStatus != nil {
		lines = append(lines, s.NetworkStatus.detailLines()...)
	}
	if s.RuntimeStatus != nil {
		for _, runtime := range s.RuntimeStatus.Runtimes {
			title := fallbackText(runtime.Title, strings.ToUpper(runtime.ID))
			state := runtime.State
			if !runtime.Enabled {
				state = "未启用"
			}
			if runtime.Version != "" {
				state += " · " + runtime.Version
			}
			lines = append(lines, title+"："+fallbackText(state, "未知"))
			lines = append(lines, runtime.quotaDetailLines()...)
		}
	}
	if !s.ServiceOK {
		if reason := firstNonEmpty(s.ServiceError, s.ProcessError); reason != "" {
			lines = append(lines, "", "原因："+reason)
		}
	}
	return strings.Join(lines, "\r\n")
}

func (r runtimeEntry) quotaDetailLines() []string {
	limits := r.RateLimits
	if limits == nil {
		return nil
	}
	if strings.EqualFold(strings.TrimSpace(limits.Availability), "unavailable") {
		reason := fallbackText(limits.UnavailableReason, "暂不可用")
		return []string{"  额度：" + reason}
	}

	lines := make([]string, 0, 3)
	if plan := firstNonEmpty(r.PlanType, limits.PlanType); plan != "" {
		lines = append(lines, "  套餐："+plan)
	}
	if limits.Primary != nil {
		lines = append(lines, "  "+limits.Primary.detailLine("主要额度"))
	}
	if limits.Secondary != nil {
		lines = append(lines, "  "+limits.Secondary.detailLine("次要额度"))
	}
	if strings.TrimSpace(limits.ReachedType) != "" {
		lines = append(lines, "  额度：已耗尽，等待窗口重置")
	}
	if limits.CreditsUnlimited != nil && *limits.CreditsUnlimited {
		lines = append(lines, "  Credits：无限")
	} else if limits.HasCredits != nil && *limits.HasCredits {
		lines = append(lines, "  Credits："+fallbackText(limits.CreditBalance, "可用"))
	}
	return lines
}

func (w runtimeRateLimitWindow) detailLine(fallbackLabel string) string {
	parts := make([]string, 0, 2)
	if w.UsedPercent != nil {
		remaining := math.Max(0, math.Min(100, 100-*w.UsedPercent))
		parts = append(parts, fmt.Sprintf("剩余 %.0f%%", remaining))
	}
	if w.ResetsAt != nil && *w.ResetsAt > 0 {
		reset := time.Unix(*w.ResetsAt, 0).Local()
		parts = append(parts, "重置 "+reset.Format("01-02 15:04"))
	}
	return quotaWindowLabel(w.WindowDurationMin, fallbackLabel) + "：" +
		fallbackText(strings.Join(parts, " · "), "等待额度数据")
}

func quotaWindowLabel(durationMinutes *int64, fallback string) string {
	if durationMinutes == nil || *durationMinutes <= 0 {
		return fallback
	}
	switch {
	case *durationMinutes%10_080 == 0:
		weeks := *durationMinutes / 10_080
		if weeks == 1 {
			return "每周额度"
		}
		return fmt.Sprintf("%d 周额度", weeks)
	case *durationMinutes%60 == 0:
		return fmt.Sprintf("%d 小时额度", *durationMinutes/60)
	default:
		return fmt.Sprintf("%d 分钟额度", *durationMinutes)
	}
}

func (s networkStatus) detailLines() []string {
	mode := map[string]string{
		"loopback":  "仅本机",
		"tailscale": "Tailscale",
		"lan":       "局域网",
		"specific":  "指定地址",
	}[strings.ToLower(strings.TrimSpace(s.Mode))]
	mode = fallbackText(mode, "未知")

	networkParts := []string{mode}
	if value := strings.TrimSpace(s.InterfaceAlias); value != "" {
		networkParts = append(networkParts, value)
	}
	if value := networkCategoryLabel(s.NetworkCategory); value != "" {
		networkParts = append(networkParts, value)
	}
	lines := []string{"网络：" + strings.Join(networkParts, " · ")}
	if !s.PolicyChecked {
		return lines
	}

	switch {
	case s.PolicyOK && s.AllowLAN:
		lines = append(lines, "防火墙：Private / LocalSubnet")
	case s.PolicyOK:
		lines = append(lines, "防火墙：未检测到额外入站放行")
	case s.PolicyInspectionErr:
		lines = append(lines, "防火墙：无法检查")
	case s.UnsafeRuleCount > 0:
		lines = append(lines, fmt.Sprintf("防火墙：需要处理（%d 条额外入站放行规则）", s.UnsafeRuleCount))
	case s.AllowLAN && !strings.EqualFold(strings.TrimSpace(s.NetworkCategory), "Private"):
		lines = append(lines, "防火墙：需要处理（当前网络不是 Private）")
	default:
		lines = append(lines, "防火墙：需要处理")
	}
	return lines
}

func networkCategoryLabel(value string) string {
	switch {
	case strings.EqualFold(strings.TrimSpace(value), "Private"):
		return "专用 (Private)"
	case strings.EqualFold(strings.TrimSpace(value), "Public"):
		return "公用 (Public)"
	case strings.EqualFold(strings.TrimSpace(value), "DomainAuthenticated"):
		return "域网络"
	default:
		return strings.TrimSpace(value)
	}
}

func fallbackText(value string, fallback string) string {
	if value = strings.TrimSpace(value); value != "" {
		return value
	}
	return fallback
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func truncateUTF16Text(value string, limit int) string {
	runes := []rune(value)
	if len(runes) <= limit {
		return value
	}
	if limit <= 1 {
		return string(runes[:limit])
	}
	return string(runes[:limit-1]) + "…"
}
