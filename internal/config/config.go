package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const AppName = "mimi-remote"

type Config struct {
	Listen        string          `json:"listen"`
	Auth          AuthConfig      `json:"auth"`
	Runtime       RuntimeConfig   `json:"runtime"`
	AppServer     AppServerConfig `json:"app_server"`
	Voice         VoiceConfig     `json:"voice"`
	Codex         CodexConfig     `json:"codex"`
	Claude        ClaudeConfig    `json:"claude"`
	Session       SessionConfig   `json:"session"`
	Debug         DebugConfig     `json:"debug"`
	Projects      []ProjectConfig `json:"projects"`
	ScanRoots     []string        `json:"scan_roots"`
	BrowseRoots   []string        `json:"browse_roots"`
	WorktreesRoot string          `json:"worktrees_root"`
	Actions       []ActionConfig  `json:"actions"`
	DevInsecure   bool            `json:"dev_insecure"`
}

type AuthConfig struct {
	Token           string `json:"token"`
	AllowQueryToken bool   `json:"allow_query_token"`
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
	Transport   string `json:"transport"`
	Managed     bool   `json:"managed"`
	Listen      string `json:"listen,omitempty"`
	WSTokenFile string `json:"ws_token_file,omitempty"`
}

type VoiceConfig struct {
	TranscriptionProvider     string `json:"transcription_provider,omitempty"`
	TranscriptionModel        string `json:"transcription_model"`
	TranscriptionBaseURL      string `json:"transcription_base_url,omitempty"`
	TranscriptionAPIKey       string `json:"transcription_api_key,omitempty"`
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

func LoadForDoctor(path string) (Config, error) {
	return load(path)
}

func load(path string) (Config, error) {
	cfg := defaults()
	path = expandPath(path)
	if path != "" {
		if b, err := os.ReadFile(path); err == nil {
			if err := json.Unmarshal(b, &cfg); err != nil {
				return Config{}, fmt.Errorf("解析配置文件失败：%w", err)
			}
		} else if !errors.Is(err, os.ErrNotExist) {
			return Config{}, fmt.Errorf("读取配置文件失败：%w", err)
		}
	}

	applyEnv(&cfg)
	cfg.Runtime.Type = normalizeRuntimeType(cfg.Runtime.Type)
	cfg.AppServer.Transport = normalizeTransport(cfg.AppServer.Transport)
	if strings.EqualFold(cfg.AppServer.Transport, "ws") && strings.TrimSpace(cfg.AppServer.Listen) == "" {
		// 旧配置迁移到 ws 后可能没有 listen；补一个默认 loopback upstream，避免 Validate 直接失败。
		cfg.AppServer.Listen = defaultAppServerListen
	}
	scanned, err := discoverProjects(cfg.ScanRoots)
	if err != nil {
		return Config{}, err
	}
	cfg.Projects = mergeProjects(cfg.Projects, scanned)
	return cfg, nil
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

// defaultAppServerListen 是托管 Codex app-server 的默认 loopback WebSocket upstream，仅本机可达。
const defaultAppServerListen = "ws://127.0.0.1:4222"

func defaults() Config {
	return Config{
		Listen: "127.0.0.1:8787",
		Runtime: RuntimeConfig{
			Type: "codex_app_server",
		},
		AppServer: AppServerConfig{
			Transport: "ws",
			Managed:   true,
			Listen:    defaultAppServerListen,
		},
		Voice: VoiceConfig{
			TranscriptionProvider:     "openai",
			TranscriptionModel:        "gpt-4o-mini-transcribe",
			TranscriptionBaseURL:      "https://api.openai.com/v1",
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
	if v := os.Getenv("AGENTD_TRANSCRIPTION_MODEL"); v != "" {
		cfg.Voice.TranscriptionModel = strings.TrimSpace(v)
	}
	if v := os.Getenv("AGENTD_TRANSCRIPTION_PROVIDER"); v != "" {
		cfg.Voice.TranscriptionProvider = strings.TrimSpace(strings.ToLower(v))
	}
	if v := os.Getenv("AGENTD_TRANSCRIPTION_BASE_URL"); v != "" {
		cfg.Voice.TranscriptionBaseURL = strings.TrimRight(strings.TrimSpace(v), "/")
	}
	if v := os.Getenv("AGENTD_CODEX_TRANSCRIPTION_BASE_URL"); v != "" {
		cfg.Voice.CodexTranscriptionBaseURL = strings.TrimRight(strings.TrimSpace(v), "/")
	} else if v := os.Getenv("CODEX_API_BASE_URL"); v != "" {
		cfg.Voice.CodexTranscriptionBaseURL = strings.TrimRight(strings.TrimSpace(v), "/")
	}
	if v := os.Getenv("AGENTD_CODEX_AUTH_FILE"); v != "" {
		cfg.Voice.CodexAuthFile = strings.TrimSpace(v)
	}
	if v := os.Getenv("AGENTD_TRANSCRIPTION_API_KEY"); v != "" {
		cfg.Voice.TranscriptionAPIKey = strings.TrimSpace(v)
	} else if v := os.Getenv("OPENAI_API_KEY"); v != "" {
		cfg.Voice.TranscriptionAPIKey = strings.TrimSpace(v)
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
	case "", "stdio", "unix", "off":
		// 旧配置平滑迁移：直连链路只保留 ws gateway，历史 stdio/unix/off 等 transport 统一归一到 ws。
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
	if c.Auth.Token == "" && !c.DevInsecure {
		return fmt.Errorf("AGENTD_TOKEN 或 auth.token 不能为空；开发临时绕过请设置 AGENTD_DEV_INSECURE=true")
	}
	if c.DevInsecure && !isLoopbackListen(c.Listen) {
		return fmt.Errorf("dev_insecure 只允许 loopback listen；远程访问必须使用 Bearer Token")
	}
	if c.Auth.Token != "" && len(c.Auth.Token) < 16 {
		return fmt.Errorf("token 太短，建议至少 32 字符")
	}
	if strings.Contains(strings.ToLower(c.Auth.Token), "change-me") {
		return fmt.Errorf("token 仍是示例占位值，请执行 agentd setup 生成随机 token")
	}
	if c.Codex.Bin == "" {
		return fmt.Errorf("codex.bin 不能为空")
	}
	if c.Claude.Enabled && strings.TrimSpace(c.Claude.BridgeBin) == "" {
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
	case "ws":
	default:
		return fmt.Errorf("app_server.transport 只支持 ws")
	}
	if strings.EqualFold(c.AppServer.Transport, "ws") && strings.TrimSpace(c.AppServer.Listen) == "" {
		return fmt.Errorf("app_server.listen 不能为空")
	}
	if strings.EqualFold(c.AppServer.Transport, "ws") && c.AppServer.Listen != "" && !isLoopbackListen(c.AppServer.Listen) {
		return fmt.Errorf("app_server.listen 只允许 loopback；iPad 应连接 agentd，不应直连 Codex app-server")
	}
	if c.Session.OutputBufferBytes <= 0 {
		return fmt.Errorf("session.output_buffer_bytes 必须大于 0")
	}
	switch strings.ToLower(strings.TrimSpace(c.Voice.TranscriptionProvider)) {
	case "", "auto", "codex", "openai":
	default:
		return fmt.Errorf("voice.transcription_provider 只支持 auto、codex 或 openai")
	}
	if len(c.Projects) == 0 {
		return fmt.Errorf("projects 不能为空；可在 config.json 配置，或设置 AGENTD_PROJECTS=/path/a,/path/b 或 AGENTD_SCAN_ROOTS=/workspace")
	}
	if err := validateActions(c.Actions); err != nil {
		return err
	}
	return nil
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
