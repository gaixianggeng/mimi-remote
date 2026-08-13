package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"

	"github.com/gaixianggeng/mimi-remote/internal/claudebridge"
)

const AppName = "mimi-remote"

type Config struct {
	Listen        string           `json:"listen"`
	Network       NetworkConfig    `json:"network"`
	Auth          AuthConfig       `json:"auth"`
	Capabilities  CapabilityConfig `json:"capabilities"`
	Runtime       RuntimeConfig    `json:"runtime"`
	AppServer     AppServerConfig  `json:"app_server"`
	Voice         VoiceConfig      `json:"voice"`
	Codex         CodexConfig      `json:"codex"`
	Claude        ClaudeConfig     `json:"claude"`
	Session       SessionConfig    `json:"session"`
	Debug         DebugConfig      `json:"debug"`
	Projects      []ProjectConfig  `json:"projects"`
	ScanRoots     []string         `json:"scan_roots"`
	BrowseRoots   []string         `json:"browse_roots"`
	WorktreesRoot string           `json:"worktrees_root"`
	Actions       []ActionConfig   `json:"actions"`
	DevInsecure   bool             `json:"dev_insecure"`
}

type NetworkConfig struct {
	// AllowLAN 是显式安全边界。关闭时继续只监听配置地址和 loopback；
	// 打开后 agentd 才会监听 IPv4 通配地址，同时服务 Tailscale 与局域网。
	AllowLAN bool `json:"allow_lan"`
}

type AuthConfig struct {
	Token           string `json:"token"`
	AllowQueryToken bool   `json:"allow_query_token"`
}

// CapabilityConfig 是仅保存在当前 Mac 配置文件中的紧急降级边界。
// disabled 允许提前写入尚未被当前版本识别的合法 capability；旧 agentd 会安全忽略，
// 升级到认识该能力的版本后则立即按本地禁用处理。
type CapabilityConfig struct {
	Disabled []string `json:"disabled,omitempty"`
}

func (c CapabilityConfig) IsDisabled(name string) bool {
	for _, disabled := range c.Disabled {
		if strings.TrimSpace(disabled) == name {
			return true
		}
	}
	return false
}

type CodexConfig struct {
	Bin         string            `json:"bin"`
	DefaultArgs []string          `json:"default_args"`
	Env         map[string]string `json:"env"`
}

type ClaudeConfig struct {
	Enabled              bool              `json:"enabled"`
	BridgeBin            string            `json:"bridge_bin"`
	Args                 []string          `json:"args,omitempty"`
	Env                  map[string]string `json:"env,omitempty"`
	MaxConcurrentBridges int               `json:"max_concurrent_bridges"`
}

type RuntimeConfig struct {
	Type string `json:"type"`
}

type AppServerConfig struct {
	Transport      string                   `json:"transport"`
	Managed        bool                     `json:"managed"`
	Listen         string                   `json:"listen,omitempty"`
	WSTokenFile    string                   `json:"ws_token_file,omitempty"`
	SharedFallback *AppServerFallbackConfig `json:"shared_fallback,omitempty"`
	// AutoTitle 只在 Mac 端通过本机 app-server 生成标题，移动端不接触 provider 凭据。
	AutoTitle bool `json:"auto_title"`
}

type AppServerFallbackConfig struct {
	Transport   string `json:"transport"`
	Managed     bool   `json:"managed"`
	Listen      string `json:"listen,omitempty"`
	WSTokenFile string `json:"ws_token_file,omitempty"`
}

type VoiceConfig struct {
	CodexTranscriptionBaseURL string `json:"codex_transcription_base_url,omitempty"`
	CodexAuthFile             string `json:"codex_auth_file,omitempty"`
}

type SessionConfig struct {
	OutputBufferBytes int `json:"output_buffer_bytes"`
}

type DebugConfig struct {
	EnableCodexHistory bool `json:"enable_codex_history"`
}

type ProjectConfig struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Path string `json:"path"`
}

type ActionConfig struct {
	ID                   string   `json:"id"`
	Name                 string   `json:"name"`
	Command              string   `json:"command"`
	Args                 []string `json:"args,omitempty"`
	WorkingDir           string   `json:"working_dir,omitempty"`
	TimeoutSeconds       int      `json:"timeout_seconds,omitempty"`
	RequiresConfirmation bool     `json:"requires_confirmation,omitempty"`
}

func DefaultPath() string {
	if v := strings.TrimSpace(os.Getenv("AGENTD_CONFIG")); v != "" {
		return v
	}
	return PlatformDefaultPath()
}

// PlatformDefaultPath 返回 Homebrew service 固定读取的平台默认配置路径。
// 它故意忽略 AGENTD_CONFIG，避免后台命令拿自定义配置做就绪检查，实际 launchd 却启动默认配置。
func PlatformDefaultPath() string {
	dir, err := UserConfigDir()
	if err != nil {
		return "config.json"
	}
	return filepath.Join(dir, "config.json")
}

// IsPlatformDefaultPath 判断目标是否就是后台服务唯一使用的平台默认配置。
// Mimi 的 launchd owner 是当前用户全局资源，不能因为操作另一个 --config
// profile 就把默认配置的 owner 删除或重建，因此所有 owner 写操作都必须先过
// 这道路径边界。
func IsPlatformDefaultPath(path string) bool {
	return SameConfigPath(path, PlatformDefaultPath())
}

// ConfigPathIdentity 返回用于跨进程配置锁的稳定路径身份。它按所在卷的
// 大小写语义规范化路径；同一默认文件的 `/Config.json` 与 `/config.json`
// 在普通 APFS 上必须取得同一把锁，而 case-sensitive APFS 上仍保持独立。
func ConfigPathIdentity(path string) (string, error) {
	absolute, err := absoluteExpandedPath(path)
	if err != nil {
		return "", err
	}
	// 配置文件本身可能尚未创建；目录存在时仍解析目录 symlink，避免同一个
	// 默认文件经不同路径写法绕过全局 owner 的归属检查。
	if canonicalDir, evalErr := filepath.EvalSymlinks(filepath.Dir(absolute)); evalErr == nil {
		absolute = filepath.Join(canonicalDir, filepath.Base(absolute))
	}
	caseSensitive, err := configPathCaseSensitive(filepath.Dir(absolute))
	if err == nil && !caseSensitive {
		absolute = strings.ToLower(absolute)
	}
	return filepath.Clean(absolute), nil
}

// SameConfigPath 比较两个配置目标的目录项身份。不能直接用 os.SameFile：两个
// 不同路径的 hard link 虽指向同一 inode，但原子 rename 只替换其中一个目录项；
// 若把它们当成默认配置，会先误删全局 owner、再只改写另一个路径。
func SameConfigPath(left, right string) bool {
	leftIdentity, leftErr := ConfigPathIdentity(left)
	rightIdentity, rightErr := ConfigPathIdentity(right)
	return leftErr == nil && rightErr == nil && leftIdentity == rightIdentity
}

func UserConfigDir() (string, error) {
	dir, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, AppName), nil
}

func Load(path string) (Config, error) {
	cfg, err := load(path)
	if err != nil {
		return Config{}, err
	}
	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

// LoadSnapshot 从调用方已经原子读取的一份配置快照解析完整 Config。共享
// daemon 的配置事务必须让 typed cfg、未知 JSON 字段与 CAS baseline 全部来自
// 同一组 bytes；不能先 Load(path) 后再 ReadFile(path)，否则并发写入会把两代
// 配置拼成一个事务。它保留普通 Load 的默认值、环境覆盖、项目发现和校验语义。
func LoadSnapshot(raw []byte) (Config, error) {
	cfg, err := loadSnapshot(raw)
	if err != nil {
		return Config{}, err
	}
	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func LoadForDoctor(path string) (Config, error) {
	return load(path)
}

func load(path string) (Config, error) {
	cfg, err := loadWithoutProjectDiscovery(path)
	if err != nil {
		return Config{}, err
	}
	scanned, err := discoverProjects(cfg.ScanRoots)
	if err != nil {
		return Config{}, err
	}
	cfg.Projects = mergeProjects(cfg.Projects, scanned)
	return cfg, nil
}

func loadSnapshot(raw []byte) (Config, error) {
	cfg, err := loadRawWithoutProjectDiscovery(raw)
	if err != nil {
		return Config{}, err
	}
	scanned, err := discoverProjects(cfg.ScanRoots)
	if err != nil {
		return Config{}, err
	}
	cfg.Projects = mergeProjects(cfg.Projects, scanned)
	return cfg, nil
}

// loadWithoutProjectDiscovery 只解析配置文件、默认值与进程级覆盖，不访问
// scan_roots。共享 daemon 的锁内所有权复核必须保持快速且只依赖相关配置，
// 不能因为无关网络盘或受保护目录暂时不可读而长期占住生命周期锁。
func loadWithoutProjectDiscovery(path string) (Config, error) {
	path = expandPath(path)
	var raw []byte
	if path != "" {
		if b, err := os.ReadFile(path); err == nil {
			raw = b
		} else if !errors.Is(err, os.ErrNotExist) {
			return Config{}, fmt.Errorf("读取配置文件失败：%w", err)
		}
	}
	return loadRawWithoutProjectDiscovery(raw)
}

func loadRawWithoutProjectDiscovery(raw []byte) (Config, error) {
	cfg := defaults()
	if raw != nil {
		listenConfigured := false
		var document map[string]json.RawMessage
		if json.Unmarshal(raw, &document) == nil {
			var appServer map[string]json.RawMessage
			if encoded, ok := document["app_server"]; ok && json.Unmarshal(encoded, &appServer) == nil {
				_, listenConfigured = appServer["listen"]
			}
		}
		if err := json.Unmarshal(raw, &cfg); err != nil {
			return Config{}, fmt.Errorf("解析配置文件失败：%w", err)
		}
		if normalizeTransport(cfg.AppServer.Transport) == "unix" && !listenConfigured {
			// defaults() 必须自身可 Validate，因此带 WS 默认 listen；但 JSON
			// 显式选 Unix 且省略 listen 时，不能把这个结构体默认误当成用户配置。
			cfg.AppServer.Listen = ""
		}
	}

	cfg.Runtime.Type = normalizeRuntimeType(cfg.Runtime.Type)
	cfg.AppServer.Transport = normalizeTransport(cfg.AppServer.Transport)
	applyEnv(&cfg)
	cfg.AppServer.Transport = normalizeTransport(cfg.AppServer.Transport)
	if strings.EqualFold(cfg.AppServer.Transport, "ws") && strings.TrimSpace(cfg.AppServer.Listen) == "" {
		// 旧配置迁移到 ws 后可能没有 listen；补一个默认 loopback upstream，避免 Validate 直接失败。
		cfg.AppServer.Listen = defaultAppServerWebSocketListen
	}
	if strings.EqualFold(cfg.AppServer.Transport, "unix") && strings.TrimSpace(cfg.AppServer.Listen) == "" {
		cfg.AppServer.Listen = defaultAppServerUnixListen
	}
	return cfg, nil
}

// ValidateSharedDaemonRecoveryOwnership 在长期存活的旧进程尝试恢复 owner 前，
// 只复核磁盘上的共享模式与 Codex 启动身份。它故意跳过 project discovery 和
// 全量 Validate；错误只会让恢复 fail closed，不影响用户修复其他配置项。
func ValidateSharedDaemonRecoveryOwnership(
	path string,
	expectedBin string,
	expectedEnv map[string]string,
) error {
	cfg, err := loadWithoutProjectDiscovery(path)
	if err != nil {
		return fmt.Errorf("重新读取 agentd 配置失败：%w", err)
	}
	if !strings.EqualFold(strings.TrimSpace(cfg.AppServer.Transport), "unix") ||
		!cfg.AppServer.Managed || cfg.AppServer.SharedFallback == nil {
		return fmt.Errorf("当前配置已取消 Mimi 共享 daemon")
	}
	if strings.TrimSpace(cfg.Codex.Bin) != strings.TrimSpace(expectedBin) ||
		!maps.Equal(cfg.Codex.Env, expectedEnv) {
		return fmt.Errorf("当前 Codex 配置已变化，旧进程不得恢复 shared daemon")
	}
	return nil
}

// ValidateSharedDaemonDisabledOwnership 是非 shared agentd 清理 Mimi 残留 owner
// 前的锁内复核。它与 recovery validator 互为相反条件：一旦另一个进程已经
// 提交新的 shared 配置，旧 WS 进程必须停止清理，不能删除刚创建的 owner。
func ValidateSharedDaemonDisabledOwnership(
	path string,
	expectedBin string,
	expectedEnv map[string]string,
) error {
	cfg, err := loadWithoutProjectDiscovery(path)
	if err != nil {
		return fmt.Errorf("重新读取 agentd 配置失败：%w", err)
	}
	if strings.EqualFold(strings.TrimSpace(cfg.AppServer.Transport), "unix") &&
		cfg.AppServer.Managed && cfg.AppServer.SharedFallback != nil {
		return fmt.Errorf("当前配置已经启用 Mimi 共享 daemon")
	}
	if strings.TrimSpace(cfg.Codex.Bin) != strings.TrimSpace(expectedBin) ||
		!maps.Equal(cfg.Codex.Env, expectedEnv) {
		return fmt.Errorf("当前 Codex 配置已变化，旧进程不得清理 shared daemon owner")
	}
	return nil
}

func expandPath(path string) string {
	value := strings.TrimSpace(path)
	if !strings.HasPrefix(value, "~/") {
		return value
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return value
	}
	return filepath.Join(home, strings.TrimPrefix(value, "~/"))
}

const (
	// defaultAppServerWebSocketListen 是兼容默认；共享 daemon 只能显式启用。
	defaultAppServerWebSocketListen = "ws://127.0.0.1:4222"
	// defaultAppServerUnixListen 使用 Codex 官方 CODEX_HOME 控制 socket。
	defaultAppServerUnixListen = "unix://"
)

func DefaultAppServerTransport() string {
	// 默认保持独立 WS，保证没有安装官方 standalone daemon 的机器仍可启动。
	// macOS 共享 daemon 会改变 Desktop 的进程环境与 app-server 所有权，必须
	// 通过 Mac 设置页 / `runtime --codex-sharing=enabled` 显式启用。
	return "ws"
}

func DefaultAppServerListen() string {
	if DefaultAppServerTransport() == "unix" {
		return defaultAppServerUnixListen
	}
	return defaultAppServerWebSocketListen
}

func DefaultAppServerWebSocketListen() string {
	return defaultAppServerWebSocketListen
}

func defaults() Config {
	return Config{
		Listen: "127.0.0.1:8787",
		Runtime: RuntimeConfig{
			Type: "codex_app_server",
		},
		AppServer: AppServerConfig{
			Transport: DefaultAppServerTransport(),
			Managed:   true,
			Listen:    DefaultAppServerListen(),
			AutoTitle: true,
		},
		Voice: VoiceConfig{
			CodexTranscriptionBaseURL: "https://chatgpt.com/backend-api",
		},
		Codex: CodexConfig{
			Bin:         "codex",
			DefaultArgs: []string{"--no-alt-screen"},
			Env: map[string]string{
				"TERM": "xterm-256color",
			},
		},
		Claude: ClaudeConfig{
			Enabled:              false,
			BridgeBin:            "alleycat-claude-bridge",
			MaxConcurrentBridges: 3,
			Env: map[string]string{
				"TERM": "xterm-256color",
			},
		},
		Session: SessionConfig{
			OutputBufferBytes: 128 * 1024,
		},
	}
}

func applyEnv(cfg *Config) {
	if v := os.Getenv("AGENTD_LISTEN"); v != "" {
		cfg.Listen = v
	} else {
		bind := os.Getenv("AGENTD_BIND")
		port := os.Getenv("AGENTD_PORT")
		if bind != "" || port != "" {
			if bind == "" {
				bind = "127.0.0.1"
			}
			if port == "" {
				port = "8787"
			}
			cfg.Listen = net.JoinHostPort(bind, port)
		}
	}
	if v := os.Getenv("AGENTD_TOKEN"); v != "" {
		cfg.Auth.Token = v
	}
	if v := os.Getenv("AGENTD_ALLOW_QUERY_TOKEN"); v == "1" || strings.EqualFold(v, "true") {
		cfg.Auth.AllowQueryToken = true
	}
	if v := os.Getenv("AGENTD_CODEX_BIN"); v != "" {
		cfg.Codex.Bin = v
	}
	if v := os.Getenv("AGENTD_CODEX_ARGS"); v != "" {
		cfg.Codex.DefaultArgs = strings.Fields(v)
	}
	if v := os.Getenv("AGENTD_CLAUDE_ENABLED"); v != "" {
		cfg.Claude.Enabled = truthy(v)
	}
	if v := os.Getenv("AGENTD_CLAUDE_BRIDGE_BIN"); v != "" {
		cfg.Claude.BridgeBin = strings.TrimSpace(v)
	}
	if v := os.Getenv("AGENTD_CLAUDE_BRIDGE_ARGS"); v != "" {
		cfg.Claude.Args = strings.Fields(v)
	}
	if v := os.Getenv("AGENTD_CLAUDE_MAX_CONCURRENT_BRIDGES"); v != "" {
		if n, err := strconv.Atoi(strings.TrimSpace(v)); err == nil {
			cfg.Claude.MaxConcurrentBridges = n
		}
	}
	if v := os.Getenv("AGENTD_APP_SERVER_TRANSPORT"); v != "" {
		cfg.AppServer.Transport = strings.TrimSpace(strings.ToLower(v))
		if strings.TrimSpace(os.Getenv("AGENTD_APP_SERVER_LISTEN")) == "" {
			// transport 显式切换时不能沿用另一种 transport 的默认 listen。
			cfg.AppServer.Listen = ""
		}
	}
	if v := os.Getenv("AGENTD_APP_SERVER_LISTEN"); v != "" {
		cfg.AppServer.Listen = strings.TrimSpace(v)
	}
	if v := os.Getenv("AGENTD_APP_SERVER_WS_TOKEN_FILE"); v != "" {
		cfg.AppServer.WSTokenFile = strings.TrimSpace(v)
	}
	if v := os.Getenv("AGENTD_APP_SERVER_MANAGED"); v != "" {
		cfg.AppServer.Managed = truthy(v)
	}
	if v := os.Getenv("AGENTD_APP_SERVER_AUTO_TITLE"); v != "" {
		cfg.AppServer.AutoTitle = truthy(v)
	}
	if v := os.Getenv("AGENTD_CODEX_TRANSCRIPTION_BASE_URL"); v != "" {
		cfg.Voice.CodexTranscriptionBaseURL = strings.TrimRight(strings.TrimSpace(v), "/")
	}
	if v := os.Getenv("AGENTD_CODEX_AUTH_FILE"); v != "" {
		cfg.Voice.CodexAuthFile = strings.TrimSpace(v)
	}
	if v := os.Getenv("AGENTD_DEV_INSECURE"); v == "1" || strings.EqualFold(v, "true") {
		cfg.DevInsecure = true
	}
	if v := os.Getenv("AGENTD_OUTPUT_BUFFER_BYTES"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			cfg.Session.OutputBufferBytes = n
		}
	}
	if v := os.Getenv("AGENTD_DEBUG_CODEX_HISTORY"); v != "" {
		cfg.Debug.EnableCodexHistory = truthy(v)
	}
	if v := os.Getenv("AGENTD_PROJECTS"); v != "" {
		cfg.Projects = parseProjectsEnv(v)
	}
	if v := os.Getenv("AGENTD_SCAN_ROOTS"); v != "" {
		cfg.ScanRoots = splitCSV(v)
	}
	if v := os.Getenv("AGENTD_BROWSE_ROOTS"); v != "" {
		cfg.BrowseRoots = splitCSV(v)
	}
	if v := os.Getenv("AGENTD_WORKTREES_ROOT"); v != "" {
		cfg.WorktreesRoot = strings.TrimSpace(v)
	}
}

func truthy(raw string) bool {
	return raw == "1" || strings.EqualFold(raw, "true") || strings.EqualFold(raw, "yes")
}

func normalizeRuntimeType(raw string) string {
	value := strings.TrimSpace(strings.ToLower(raw))
	switch value {
	case "app_server", "app-server", "codex-app-server":
		return "codex_app_server"
	case "pty":
		// 旧配置平滑迁移：不再启动 PTY runtime，只把历史字段归一到当前 app-server 链路。
		return "codex_app_server"
	default:
		return value
	}
}

func normalizeTransport(raw string) string {
	value := strings.TrimSpace(strings.ToLower(raw))
	switch value {
	case "":
		return DefaultAppServerTransport()
	case "unix":
		return "unix"
	case "stdio", "off":
		// 历史 stdio/off 配置继续按旧行为迁移到独立 WS runtime。共享 daemon
		// 会改变进程所有权，必须由用户通过 codex-sharing 显式启用，不能在升级时静默切换。
		return "ws"
	default:
		return value
	}
}

func parseProjectsEnv(raw string) []ProjectConfig {
	parts := splitCSV(raw)
	projects := make([]ProjectConfig, 0, len(parts))
	seen := map[string]int{}
	for _, path := range parts {
		name := filepath.Base(path)
		id := sanitizeID(name)
		seen[id]++
		if seen[id] > 1 {
			id = fmt.Sprintf("%s-%d", id, seen[id])
		}
		projects = append(projects, ProjectConfig{ID: id, Name: name, Path: path})
	}
	return projects
}

func splitCSV(raw string) []string {
	parts := strings.Split(raw, ",")
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		item := strings.TrimSpace(part)
		if item != "" {
			out = append(out, item)
		}
	}
	return out
}

func discoverProjects(roots []string) ([]ProjectConfig, error) {
	var projects []ProjectConfig
	for _, root := range roots {
		abs, err := filepath.Abs(root)
		if err != nil {
			return nil, fmt.Errorf("解析扫描根目录失败 %s：%w", root, err)
		}
		entries, err := os.ReadDir(abs)
		if err != nil {
			return nil, fmt.Errorf("读取扫描根目录失败 %s：%w", abs, err)
		}

		// 根目录本身也加入，方便用户仍然能在整个工作区运行 Codex。
		projects = append(projects, projectFromPath(abs))
		for _, entry := range entries {
			if !entry.IsDir() || skipScanDir(entry.Name()) {
				continue
			}
			child := filepath.Join(abs, entry.Name())
			projects = append(projects, projectFromPath(child))
		}
	}
	return projects, nil
}

func skipScanDir(name string) bool {
	if strings.HasPrefix(name, ".") {
		return true
	}
	switch name {
	case "node_modules", "vendor", "dist", "build", "target", "tmp", "temp":
		return true
	default:
		return false
	}
}

func projectFromPath(path string) ProjectConfig {
	name := filepath.Base(path)
	return ProjectConfig{ID: sanitizeID(name), Name: name, Path: path}
}

func mergeProjects(explicit, scanned []ProjectConfig) []ProjectConfig {
	merged := make([]ProjectConfig, 0, len(explicit)+len(scanned))
	seenPath := map[string]bool{}
	seenID := map[string]int{}
	add := func(project ProjectConfig) {
		abs, err := filepath.Abs(project.Path)
		if err == nil {
			project.Path = abs
		}
		key := project.Path
		if seenPath[key] {
			return
		}
		seenPath[key] = true
		if project.ID == "" {
			project.ID = sanitizeID(filepath.Base(project.Path))
		}
		baseID := project.ID
		seenID[baseID]++
		if seenID[baseID] > 1 {
			project.ID = fmt.Sprintf("%s-%d", baseID, seenID[baseID])
		}
		if project.Name == "" {
			project.Name = filepath.Base(project.Path)
		}
		merged = append(merged, project)
	}
	for _, project := range explicit {
		add(project)
	}
	for _, project := range scanned {
		add(project)
	}
	return merged
}

func sanitizeID(raw string) string {
	raw = strings.ToLower(raw)
	var b strings.Builder
	for _, r := range raw {
		switch {
		case r >= 'a' && r <= 'z':
			b.WriteRune(r)
		case r >= '0' && r <= '9':
			b.WriteRune(r)
		case r == '-' || r == '_':
			b.WriteRune(r)
		default:
			b.WriteRune('-')
		}
	}
	id := strings.Trim(b.String(), "-_")
	if id == "" {
		return "project"
	}
	return id
}

func (c Config) Validate() error {
	if c.Listen == "" {
		return fmt.Errorf("listen 不能为空")
	}
	if err := validateAgentListen(c.Listen, c.Network.AllowLAN); err != nil {
		return err
	}
	if c.Auth.Token == "" && !c.DevInsecure {
		return fmt.Errorf("AGENTD_TOKEN 或 auth.token 不能为空；开发临时绕过请设置 AGENTD_DEV_INSECURE=true")
	}
	if c.DevInsecure && (!isLoopbackListen(c.Listen) || c.Network.AllowLAN) {
		return fmt.Errorf("dev_insecure 只允许 loopback listen 且不能启用局域网；远程访问必须使用 Bearer Token")
	}
	if c.Auth.Token != "" && len(c.Auth.Token) < 16 {
		return fmt.Errorf("token 太短，建议至少 32 字符")
	}
	if strings.Contains(strings.ToLower(c.Auth.Token), "change-me") {
		return fmt.Errorf("token 仍是示例占位值，请执行 agentd setup 生成随机 token")
	}
	if err := validateCapabilities(c.Capabilities); err != nil {
		return err
	}
	if c.Codex.Bin == "" {
		return fmt.Errorf("codex.bin 不能为空")
	}
	if c.Claude.Enabled && strings.TrimSpace(c.Claude.BridgeBin) == "" && !claudebridge.BundledAvailable() {
		return fmt.Errorf("claude.bridge_bin 不能为空")
	}
	if c.Claude.Enabled && c.Claude.MaxConcurrentBridges <= 0 {
		return fmt.Errorf("claude.max_concurrent_bridges 必须大于 0")
	}
	switch normalizeRuntimeType(c.Runtime.Type) {
	case "codex_app_server":
	default:
		return fmt.Errorf("runtime.type 只支持 codex_app_server")
	}
	switch strings.ToLower(strings.TrimSpace(c.AppServer.Transport)) {
	case "ws", "unix":
	default:
		return fmt.Errorf("app_server.transport 只支持 ws 或 unix")
	}
	if strings.EqualFold(c.AppServer.Transport, "ws") && strings.TrimSpace(c.AppServer.Listen) == "" {
		return fmt.Errorf("app_server.listen 不能为空")
	}
	if strings.EqualFold(c.AppServer.Transport, "ws") && c.AppServer.Listen != "" && !isLoopbackListen(c.AppServer.Listen) {
		return fmt.Errorf("app_server.listen 只允许 loopback；iPad 应连接 agentd，不应直连 Codex app-server")
	}
	if strings.EqualFold(c.AppServer.Transport, "unix") {
		if runtime.GOOS == "windows" {
			return fmt.Errorf("app_server.transport=unix 不支持 Windows")
		}
		if listen := strings.TrimSpace(c.AppServer.Listen); listen != "" && listen != defaultAppServerUnixListen {
			return fmt.Errorf("共享 Codex local daemon 只支持 app_server.listen=unix://")
		}
	}
	if fallback := c.AppServer.SharedFallback; fallback != nil {
		// shared_fallback 是关闭共享模式时唯一的可恢复点；加载时就验证，避免
		// “启用看似成功、真正需要回滚时才发现配置不可用”。
		if !strings.EqualFold(strings.TrimSpace(c.AppServer.Transport), "unix") {
			return fmt.Errorf("app_server.shared_fallback 只允许用于共享 Unix transport")
		}
		if !strings.EqualFold(strings.TrimSpace(fallback.Transport), "ws") {
			return fmt.Errorf("app_server.shared_fallback.transport 只支持 ws")
		}
		if strings.TrimSpace(fallback.Listen) == "" || !isLoopbackListen(fallback.Listen) {
			return fmt.Errorf("app_server.shared_fallback.listen 只允许 loopback WebSocket")
		}
	}
	if c.Session.OutputBufferBytes <= 0 {
		return fmt.Errorf("session.output_buffer_bytes 必须大于 0")
	}
	if len(c.Projects) == 0 {
		return fmt.Errorf("projects 不能为空；可在 config.json 配置，或设置 AGENTD_PROJECTS=/path/a,/path/b 或 AGENTD_SCAN_ROOTS=/workspace")
	}
	if err := validateActions(c.Actions); err != nil {
		return err
	}
	return nil
}

func validateCapabilities(capabilities CapabilityConfig) error {
	if len(capabilities.Disabled) > 32 {
		return fmt.Errorf("capabilities.disabled 最多配置 32 项")
	}
	seen := map[string]bool{}
	for index, raw := range capabilities.Disabled {
		name := strings.TrimSpace(raw)
		if !validCapabilityName(name) {
			return fmt.Errorf("capabilities.disabled[%d] 必须使用小写 snake_case_vN 格式", index)
		}
		if seen[name] {
			return fmt.Errorf("capabilities.disabled 重复：%s", name)
		}
		seen[name] = true
	}
	return nil
}

func validCapabilityName(name string) bool {
	versionSeparator := strings.LastIndex(name, "_v")
	if versionSeparator <= 0 || versionSeparator+2 >= len(name) {
		return false
	}
	base, version := name[:versionSeparator], name[versionSeparator+2:]
	if version[0] < '1' || version[0] > '9' {
		return false
	}
	for _, char := range version[1:] {
		if char < '0' || char > '9' {
			return false
		}
	}
	if base[0] < 'a' || base[0] > 'z' {
		return false
	}
	for _, char := range base[1:] {
		if (char < 'a' || char > 'z') && (char < '0' || char > '9') && char != '_' {
			return false
		}
	}
	return !strings.Contains(base, "__") && !strings.HasSuffix(base, "_")
}

func validateActions(actions []ActionConfig) error {
	if len(actions) > 50 {
		return fmt.Errorf("actions 最多配置 50 个")
	}
	seen := map[string]bool{}
	for index, action := range actions {
		prefix := fmt.Sprintf("actions[%d]", index)
		id := strings.TrimSpace(action.ID)
		if id == "" {
			return fmt.Errorf("%s.id 不能为空", prefix)
		}
		if !isSafeConfigID(id) {
			return fmt.Errorf("%s.id 只能包含字母、数字、下划线和短横线", prefix)
		}
		if seen[id] {
			return fmt.Errorf("actions.id 重复：%s", id)
		}
		seen[id] = true
		if strings.TrimSpace(action.Name) == "" {
			return fmt.Errorf("%s.name 不能为空", prefix)
		}
		command := strings.TrimSpace(action.Command)
		if command == "" {
			return fmt.Errorf("%s.command 不能为空", prefix)
		}
		if strings.ContainsRune(command, '\x00') || strings.ContainsAny(command, " \t\r\n") {
			return fmt.Errorf("%s.command 必须是单个可执行文件路径或 PATH 命令名，参数请放到 args", prefix)
		}
		if strings.ContainsRune(action.WorkingDir, '\x00') {
			return fmt.Errorf("%s.working_dir 不能包含非法字符", prefix)
		}
		if action.TimeoutSeconds < 0 || action.TimeoutSeconds > 120 {
			return fmt.Errorf("%s.timeout_seconds 必须在 0 到 120 秒之间", prefix)
		}
		if len(action.Args) > 64 {
			return fmt.Errorf("%s.args 最多 64 项", prefix)
		}
		for argIndex, arg := range action.Args {
			if strings.ContainsRune(arg, '\x00') {
				return fmt.Errorf("%s.args[%d] 不能包含非法字符", prefix, argIndex)
			}
			if len([]rune(arg)) > 1024 {
				return fmt.Errorf("%s.args[%d] 最多 1024 个字符", prefix, argIndex)
			}
		}
	}
	return nil
}

func isSafeConfigID(raw string) bool {
	for _, r := range raw {
		switch {
		case r >= 'a' && r <= 'z':
		case r >= 'A' && r <= 'Z':
		case r >= '0' && r <= '9':
		case r == '-' || r == '_':
		default:
			return false
		}
	}
	return true
}

func isLoopbackListen(raw string) bool {
	value := strings.TrimSpace(raw)
	if value == "" {
		return true
	}
	if strings.Contains(value, "://") {
		parsed, err := url.Parse(value)
		if err != nil {
			return false
		}
		value = parsed.Host
	}

	host := value
	if parsedHost, _, err := net.SplitHostPort(value); err == nil {
		host = parsedHost
	} else if strings.HasPrefix(value, "[") && strings.HasSuffix(value, "]") {
		host = strings.TrimPrefix(strings.TrimSuffix(value, "]"), "[")
	}
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func validateAgentListen(raw string, allowLAN bool) error {
	value := strings.TrimSpace(raw)
	host, port, err := net.SplitHostPort(value)
	if err != nil || strings.TrimSpace(port) == "" {
		return fmt.Errorf("listen 必须是 host:port，实际为 %q", raw)
	}
	host = strings.Trim(strings.TrimSpace(host), "[]")
	if strings.EqualFold(host, "localhost") {
		return nil
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return fmt.Errorf("listen 只允许 loopback、Tailscale 或私有局域网 IP，不能使用主机名或公网地址：%q", host)
	}
	if ip.IsLoopback() || isTailscaleListenIP(ip) {
		return nil
	}
	if ip.IsUnspecified() || ip.IsPrivate() {
		if !allowLAN {
			return fmt.Errorf("listen %q 会暴露到局域网，必须同时设置 network.allow_lan=true", raw)
		}
		return nil
	}
	return fmt.Errorf("listen 不能绑定公网或非私有地址：%q", host)
}

func isTailscaleListenIP(ip net.IP) bool {
	if v4 := ip.To4(); v4 != nil {
		return v4[0] == 100 && v4[1] >= 64 && v4[1] <= 127
	}
	return false
}
