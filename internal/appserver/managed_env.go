package appserver

import (
	"os"
	"strings"
)

// 受管子进程共用的环境与诊断处理：SSH 传输、共享本地 app-server 和
// Windows 本地 WebSocket app-server 都走这里。
func buildManagedEnv(extra map[string]string) []string {
	// 受管 App Server 必须保持独立。旧实验版本可能在 launchd 会话中留下
	// Desktop transport 环境；无论它来自继承环境还是 codex.env，都不能透传。
	filtered := map[string]struct{}{
		"CODEX_APP_SERVER_USE_LOCAL_DAEMON":         {},
		"CODEX_APP_SERVER_WS_URL":                   {},
		"MIMI_REMOTE_CODEX_DESKTOP_OWNERSHIP_EPOCH": {},
	}
	values := make(map[string]string, len(os.Environ())+len(extra))
	order := make([]string, 0, len(os.Environ())+len(extra))
	for _, entry := range os.Environ() {
		key, value, ok := strings.Cut(entry, "=")
		if !ok || strings.TrimSpace(key) == "" {
			continue
		}
		if _, blocked := filtered[key]; blocked {
			continue
		}
		if _, exists := values[key]; !exists {
			order = append(order, key)
		}
		values[key] = value
	}
	for k, v := range extra {
		if strings.TrimSpace(k) == "" {
			continue
		}
		if _, blocked := filtered[k]; blocked {
			continue
		}
		if _, exists := values[k]; !exists {
			order = append(order, k)
		}
		values[k] = v
	}
	env := make([]string, 0, len(order))
	for _, key := range order {
		env = append(env, key+"="+values[key])
	}
	return env
}

func sanitizeDiagnostic(value string) string {
	line := strings.TrimSpace(value)
	if line == "" {
		return ""
	}
	redactKeys := []string{"token", "secret", "password", "authorization", "bearer"}
	lower := strings.ToLower(line)
	for _, key := range redactKeys {
		if strings.Contains(lower, key) {
			return "[redacted sensitive app-server diagnostic]"
		}
	}
	return line
}

// 子进程被我们主动 kill 时，Wait 返回的信号错误不算关停失败。
func ignoreKilledProcessError(err error) error {
	if err == nil {
		return nil
	}
	if strings.Contains(err.Error(), "signal: killed") {
		return nil
	}
	return err
}
