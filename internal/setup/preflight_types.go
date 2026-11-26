package setup

import (
	"context"
	"net"
	"strings"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

type PreflightOptions struct {
	// The managed CLI verifies the OS owner of this socket before sending its bearer.
	HostDial                                         func(context.Context, string, string) (net.Conn, error)
	Stage, ConfigPath, ScanRoot, BrowseRoot, Version string
	LegacyPath                                       string
	RuntimePaths, Assistants                         map[string]string
}

type PreflightHost struct {
	LANPolicyCode  *string           `json:"lan_policy_code,omitempty"`
	Generation     string            `json:"generation,omitempty"`
	Version        string            `json:"version"`
	Ready          bool              `json:"ready"`
	Assistants     map[string]bool   `json:"assistants"`
	Networks       map[string]bool   `json:"networks"`
	Accounts       map[string]string `json:"accounts"`
	FolderDenied   bool              `json:"folder_denied"`
	TailcatRunning bool              `json:"tailcat_running"`
}

type PreflightCandidate struct {
	Path    string `json:"path"`
	Outcome string `json:"outcome"`
	Version string `json:"version,omitempty"`
}

type PreflightObservation struct {
	Available                                 *bool
	Code, Source, DetectedVersion, MinVersion string
	Candidates                                []PreflightCandidate
}

type PreflightProbes struct {
	Platform      string
	Host          func(context.Context, config.Config) (PreflightHost, error)
	Member        func(context.Context, string, config.Config, string, PreflightHost) PreflightObservation
	HomebrewOwner func(context.Context) bool
}

type PreflightCheck struct {
	ID       string         `json:"id"`
	Group    string         `json:"group"`
	State    string         `json:"state"`
	Title    string         `json:"title"`
	Detail   string         `json:"detail"`
	Blocking bool           `json:"blocking"`
	Code     string         `json:"code,omitempty"`
	Fix      *OnboardingFix `json:"fix,omitempty"`
	Enabled  *bool          `json:"enabled,omitempty"`
	// A member with unknown availability must emit JSON null. Aggregate and
	// structural rows omit this field entirely.
	Available       **bool                `json:"available,omitempty"`
	Candidates      *[]PreflightCandidate `json:"candidates,omitempty"`
	DetectedVersion string                `json:"detected_version,omitempty"`
	MinVersion      string                `json:"min_version,omitempty"`
	Source          string                `json:"source,omitempty"`
	ConfigPath      string                `json:"config_path,omitempty"`
	RecoveryPath    string                `json:"recovery_path,omitempty"`
}
type PreflightReport struct {
	Schema               string           `json:"schema"`
	OK                   bool             `json:"ok"`
	Stage                string           `json:"stage"`
	Configured           bool             `json:"configured"`
	WorkspaceConfirmed   bool             `json:"workspace_confirmed"`
	ConfigPath           string           `json:"config_path"`
	ScanRoot             string           `json:"scan_root"`
	BrowseRoot           string           `json:"browse_root"`
	ScanRootExists       bool             `json:"scan_root_exists"`
	RecommendedNext      string           `json:"recommended_next"`
	RecommendedTransport *string          `json:"recommended_transport"`
	Checks               []PreflightCheck `json:"checks"`
}

var preflightTitles = map[string]string{
	"config_store": "配置文件", "workspace_root": "代码目录", "service_owner_conflict": "后台服务归属", "service_daemon": "后台服务",
	"assistant_codex": "Codex 助手", "assistant_claude": "Claude Code 助手", "assistant_agy": "Antigravity 助手", "assistant_deepseek": "DeepSeek 助手", "assistant_any": "可用助手",
	"network_tailscale": "Tailscale 连接", "network_tailcat": "内置连接", "network_lan": "同一局域网", "network_any": "手机连接方式",
	"permission_login_item": "登录项", "permission_folder_access": "文件夹访问权限", "permission_local_network": "本地网络权限", "permission_photos": "照片权限", "permission_full_disk": "完全磁盘访问权限",
}

func preflightRows(platform string) []PreflightCheck {
	ids := []string{"config_store", "workspace_root"}
	if platform == "darwin" || platform == "macos" {
		ids = append(ids, "service_owner_conflict")
	}
	ids = append(ids, "service_daemon", "assistant_codex", "assistant_claude", "assistant_agy", "assistant_deepseek", "assistant_any", "network_tailscale", "network_tailcat", "network_lan", "network_any")
	switch platform {
	case "darwin", "macos":
		ids = append(ids, "permission_login_item", "permission_folder_access", "permission_local_network", "permission_photos", "permission_full_disk")
	case "windows":
		ids = append(ids, "permission_local_network")
	}
	rows := make([]PreflightCheck, 0, len(ids))
	for _, id := range ids {
		group, _, _ := strings.Cut(id, "_")
		if id == "config_store" {
			group = "workspace"
		}
		row := PreflightCheck{ID: id, Group: group, State: "checking", Title: preflightTitles[id], Detail: "正在检查。"}
		if (group == "assistant" || group == "network") && id != group+"_any" {
			row.Enabled = new(bool)
			row.Available = new(*bool)
		}
		if id == "assistant_codex" || id == "assistant_claude" || id == "assistant_agy" {
			empty := []PreflightCandidate{}
			row.Candidates = &empty
		}
		rows = append(rows, row)
	}
	return rows
}
