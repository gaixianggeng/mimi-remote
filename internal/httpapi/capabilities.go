package httpapi

import (
	"bufio"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

type capabilityListRequest struct {
	Path string `json:"path,omitempty"`
}

type capabilityListResponse struct {
	Path       string                `json:"path,omitempty"`
	Skills     []skillCapability     `json:"skills"`
	MCPServers []mcpServerCapability `json:"mcp_servers"`
}

type skillCapability struct {
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	Scope       string `json:"scope"`
	Path        string `json:"path"`
	Enabled     bool   `json:"enabled"`
}

type mcpServerCapability struct {
	Name       string `json:"name"`
	Scope      string `json:"scope"`
	ConfigPath string `json:"config_path"`
	Transport  string `json:"transport,omitempty"`
	Command    string `json:"command,omitempty"`
	URL        string `json:"url,omitempty"`
	Enabled    bool   `json:"enabled"`
	Plugin     string `json:"plugin,omitempty"`
	Status     string `json:"status,omitempty"`
	StatusNote string `json:"status_note,omitempty"`
}

func (r *Router) capabilityListHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}

	var payload capabilityListRequest
	if !decodeJSONRequest(w, req, &payload) {
		return
	}

	path := strings.TrimSpace(payload.Path)
	var realPath string
	var boundaryPath string
	if path != "" {
		scope, ok := r.gatewayScopeForPath(path)
		if !ok {
			writeError(w, http.StatusForbidden, "路径不在允许范围内或不可访问")
			return
		}
		realPath = scope.realPath
		stat, err := os.Stat(realPath)
		if err != nil {
			writeError(w, http.StatusForbidden, "路径不在允许范围内或不可访问")
			return
		}
		if !stat.IsDir() {
			writeError(w, http.StatusBadRequest, "路径不是目录")
			return
		}
		boundaryPath = r.commandActionScopeRoot(scope)
		if boundaryPath == "" {
			boundaryPath = realPath
		}
	}

	writeJSON(w, http.StatusOK, capabilityListResponse{
		Path:       realPath,
		Skills:     discoverSkillCapabilities(realPath, boundaryPath),
		MCPServers: discoverMCPCapabilities(realPath, boundaryPath),
	})
}

func discoverSkillCapabilities(realPath string, boundaryPath string) []skillCapability {
	var roots []capabilityRoot
	if realPath != "" {
		for _, dir := range projectCapabilityDirs(realPath, boundaryPath) {
			roots = append(roots, capabilityRoot{path: filepath.Join(dir, ".agents", "skills"), scope: "repo"})
			roots = append(roots, capabilityRoot{path: filepath.Join(dir, ".codex", "skills"), scope: "repo"})
		}
	}
	if home, err := os.UserHomeDir(); err == nil {
		roots = append(roots, capabilityRoot{path: filepath.Join(home, ".agents", "skills"), scope: "user"})
		roots = append(roots, capabilityRoot{path: filepath.Join(home, ".codex", "skills"), scope: "user"})
	}
	roots = append(roots, capabilityRoot{path: "/etc/codex/skills", scope: "admin"})

	seen := map[string]bool{}
	var out []skillCapability
	for _, root := range roots {
		items := skillsInRoot(root)
		for _, item := range items {
			key := item.Path
			if seen[key] {
				continue
			}
			seen[key] = true
			out = append(out, item)
		}
	}
	return out
}

func skillsInRoot(root capabilityRoot) []skillCapability {
	entries, err := os.ReadDir(root.path)
	if err != nil {
		return nil
	}
	var out []skillCapability
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		path := filepath.Join(root.path, entry.Name(), "SKILL.md")
		info, err := os.Stat(path)
		if err != nil || info.IsDir() {
			continue
		}
		name, description := parseSkillMetadata(path)
		if strings.TrimSpace(name) == "" {
			name = entry.Name()
		}
		out = append(out, skillCapability{
			Name:        name,
			Description: description,
			Scope:       root.scope,
			Path:        path,
			Enabled:     true,
		})
	}
	return out
}

func parseSkillMetadata(path string) (string, string) {
	file, err := os.Open(path)
	if err != nil {
		return "", ""
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	inFrontmatter := false
	frontmatterStarted := false
	var name string
	var description string
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if !frontmatterStarted {
			if line == "---" {
				frontmatterStarted = true
				inFrontmatter = true
				continue
			}
			break
		}
		if inFrontmatter && line == "---" {
			break
		}
		if !inFrontmatter {
			break
		}
		key, value, ok := parseSimpleYAMLScalar(line)
		if !ok {
			continue
		}
		switch key {
		case "name":
			name = value
		case "description":
			description = value
		}
	}
	return name, description
}

func parseSimpleYAMLScalar(line string) (string, string, bool) {
	key, value, ok := strings.Cut(line, ":")
	if !ok {
		return "", "", false
	}
	key = strings.TrimSpace(key)
	value = strings.TrimSpace(value)
	value = strings.Trim(value, `"'`)
	return key, value, key != ""
}

func discoverMCPCapabilities(realPath string, boundaryPath string) []mcpServerCapability {
	var configs []capabilityRoot
	if realPath != "" {
		for _, dir := range projectCapabilityDirs(realPath, boundaryPath) {
			configs = append(configs, capabilityRoot{path: filepath.Join(dir, ".codex", "config.toml"), scope: "repo"})
		}
	}
	if home, err := os.UserHomeDir(); err == nil {
		configs = append(configs, capabilityRoot{path: filepath.Join(home, ".codex", "config.toml"), scope: "user"})
	}

	seen := map[string]bool{}
	var out []mcpServerCapability
	for _, cfg := range configs {
		servers := mcpServersInConfig(cfg.path, cfg.scope)
		for _, server := range servers {
			key := server.ConfigPath + "#" + server.Plugin + "#" + server.Name
			if seen[key] {
				continue
			}
			seen[key] = true
			out = append(out, server)
		}
	}
	return out
}

func mcpServersInConfig(path string, scope string) []mcpServerCapability {
	file, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer file.Close()

	servers := map[string]*mcpServerCapability{}
	var current *mcpServerCapability
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section := strings.TrimSpace(strings.TrimSuffix(strings.TrimPrefix(line, "["), "]"))
			name, plugin, ok := mcpServerNameFromTOMLSection(section)
			if !ok {
				current = nil
				continue
			}
			key := plugin + "#" + name
			if servers[key] == nil {
				servers[key] = &mcpServerCapability{
					Name:       name,
					Scope:      scope,
					ConfigPath: path,
					Enabled:    true,
					Plugin:     plugin,
				}
			}
			current = servers[key]
			continue
		}
		if current == nil {
			continue
		}
		key, rawValue, ok := parseSimpleTOMLAssignment(line)
		if !ok {
			continue
		}
		switch key {
		case "command":
			current.Command = parseTOMLString(rawValue)
			if current.Command != "" {
				current.Transport = "stdio"
			}
		case "url":
			current.URL = parseTOMLString(rawValue)
			if current.URL != "" {
				current.Transport = "http"
			}
		case "enabled":
			current.Enabled = !strings.EqualFold(strings.TrimSpace(rawValue), "false")
		}
	}

	out := make([]mcpServerCapability, 0, len(servers))
	for _, server := range servers {
		item := *server
		fillMCPServerStatus(&item)
		out = append(out, item)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Scope != out[j].Scope {
			return out[i].Scope < out[j].Scope
		}
		if out[i].Plugin != out[j].Plugin {
			return out[i].Plugin < out[j].Plugin
		}
		return out[i].Name < out[j].Name
	})
	return out
}

func fillMCPServerStatus(server *mcpServerCapability) {
	if server == nil {
		return
	}
	if !server.Enabled {
		server.Status = "disabled"
		server.StatusNote = "配置已停用"
		return
	}

	switch server.Transport {
	case "stdio":
		command := strings.TrimSpace(server.Command)
		if command == "" {
			server.Status = "invalid"
			server.StatusNote = "stdio MCP 缺少 command"
			return
		}
		if commandAvailable(command) {
			server.Status = "ready"
			server.StatusNote = "命令可执行"
			return
		}
		server.Status = "missing_command"
		server.StatusNote = "找不到 command，检查 PATH 或绝对路径"
	case "http":
		if strings.TrimSpace(server.URL) == "" {
			server.Status = "invalid"
			server.StatusNote = "HTTP MCP 缺少 url"
			return
		}
		// 这里只做本地配置体检，不发起网络请求，避免刷新能力页时启动远端登录或泄露访问痕迹。
		server.Status = "configured"
		server.StatusNote = "HTTP 配置存在，未发起网络探测"
	default:
		server.Status = "invalid"
		server.StatusNote = "缺少 command 或 url"
	}
}

func commandAvailable(command string) bool {
	command = strings.TrimSpace(command)
	if command == "" {
		return false
	}
	if filepath.IsAbs(command) || strings.ContainsAny(command, `/\`) {
		info, err := os.Stat(command)
		return err == nil && !info.IsDir() && info.Mode().Perm()&0o111 != 0
	}
	_, err := exec.LookPath(command)
	return err == nil
}

func mcpServerNameFromTOMLSection(section string) (string, string, bool) {
	const directPrefix = "mcp_servers."
	if strings.HasPrefix(section, directPrefix) {
		name, _ := firstTOMLSegment(strings.TrimPrefix(section, directPrefix))
		return name, "", name != ""
	}
	marker := ".mcp_servers."
	index := strings.Index(section, marker)
	if !strings.HasPrefix(section, "plugins.") || index < 0 {
		return "", "", false
	}
	pluginRaw := strings.TrimPrefix(section[:index], "plugins.")
	plugin, _ := firstTOMLSegment(pluginRaw)
	name, _ := firstTOMLSegment(section[index+len(marker):])
	return name, plugin, name != ""
}

func firstTOMLSegment(raw string) (string, string) {
	value := strings.TrimSpace(raw)
	if value == "" {
		return "", ""
	}
	if strings.HasPrefix(value, `"`) {
		var b strings.Builder
		escaped := false
		for i, r := range value[1:] {
			if escaped {
				b.WriteRune(r)
				escaped = false
				continue
			}
			if r == '\\' {
				escaped = true
				continue
			}
			if r == '"' {
				return b.String(), strings.TrimPrefix(value[i+2:], ".")
			}
			b.WriteRune(r)
		}
		return b.String(), ""
	}
	name, rest, _ := strings.Cut(value, ".")
	return strings.TrimSpace(name), rest
}

func parseSimpleTOMLAssignment(line string) (string, string, bool) {
	key, value, ok := strings.Cut(line, "=")
	if !ok {
		return "", "", false
	}
	key = strings.TrimSpace(key)
	if key == "" || strings.Contains(key, ".") {
		return "", "", false
	}
	return key, strings.TrimSpace(value), true
}

func parseTOMLString(raw string) string {
	value := strings.TrimSpace(raw)
	if len(value) < 2 || !strings.HasPrefix(value, `"`) {
		return ""
	}
	var b strings.Builder
	escaped := false
	for _, r := range value[1:] {
		if escaped {
			b.WriteRune(r)
			escaped = false
			continue
		}
		if r == '\\' {
			escaped = true
			continue
		}
		if r == '"' {
			return b.String()
		}
		b.WriteRune(r)
	}
	return ""
}

func projectCapabilityDirs(realPath string, boundaryPath string) []string {
	if realPath == "" {
		return nil
	}
	gitRoot := nearestGitRoot(realPath)
	boundary := cleanCapabilityBoundary(boundaryPath)
	if gitRoot == "" {
		return []string{filepath.Clean(realPath)}
	}
	if boundary != "" && realPathWithin(boundary, filepath.Clean(realPath)) && !realPathWithin(boundary, gitRoot) {
		gitRoot = boundary
	}
	var dirs []string
	current := filepath.Clean(realPath)
	for {
		dirs = append(dirs, current)
		if current == gitRoot || current == boundary {
			break
		}
		parent := filepath.Dir(current)
		if parent == current {
			break
		}
		current = parent
	}
	return dirs
}

func cleanCapabilityBoundary(boundaryPath string) string {
	value := strings.TrimSpace(boundaryPath)
	if value == "" {
		return ""
	}
	abs, err := filepath.Abs(value)
	if err != nil {
		return filepath.Clean(value)
	}
	if realPath, err := filepath.EvalSymlinks(abs); err == nil {
		return filepath.Clean(realPath)
	}
	return filepath.Clean(abs)
}

func nearestGitRoot(realPath string) string {
	current := filepath.Clean(realPath)
	for {
		if _, err := os.Stat(filepath.Join(current, ".git")); err == nil {
			return current
		}
		parent := filepath.Dir(current)
		if parent == current {
			return ""
		}
		current = parent
	}
}

type capabilityRoot struct {
	path  string
	scope string
}
