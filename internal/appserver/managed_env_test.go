package appserver

import (
	"strings"
	"testing"
)

func TestBuildManagedEnvFiltersLegacyDesktopTransportAndOverlaysConfiguredValues(t *testing.T) {
	t.Setenv("CODEX_APP_SERVER_USE_LOCAL_DAEMON", "1")
	t.Setenv("CODEX_APP_SERVER_WS_URL", "ws://desktop-only.invalid")
	t.Setenv("MIMI_REMOTE_CODEX_DESKTOP_OWNERSHIP_EPOCH", "desktop-owner-token")
	t.Setenv("MIMI_MANAGED_ENV_TEST", "inherited")
	t.Setenv("CODEX_HOME", "/inherited/codex")

	env := buildManagedEnv(map[string]string{
		"CODEX_APP_SERVER_USE_LOCAL_DAEMON":         "1",
		"CODEX_APP_SERVER_WS_URL":                   "ws://still-blocked.invalid",
		"MIMI_REMOTE_CODEX_DESKTOP_OWNERSHIP_EPOCH": "still-blocked-owner-token",
		"MIMI_MANAGED_ENV_TEST":                     "configured",
		"CODEX_HOME":                                "/configured/codex",
	})
	values := map[string]string{}
	counts := map[string]int{}
	for _, entry := range env {
		key, value, ok := strings.Cut(entry, "=")
		if !ok {
			continue
		}
		values[key] = value
		counts[key]++
	}
	for _, key := range []string{
		"CODEX_APP_SERVER_USE_LOCAL_DAEMON",
		"CODEX_APP_SERVER_WS_URL",
		"MIMI_REMOTE_CODEX_DESKTOP_OWNERSHIP_EPOCH",
	} {
		if _, exists := values[key]; exists {
			t.Fatalf("旧 Desktop transport 环境不能泄漏到受管 App Server：%s", key)
		}
	}
	if values["MIMI_MANAGED_ENV_TEST"] != "configured" || counts["MIMI_MANAGED_ENV_TEST"] != 1 {
		t.Fatalf("显式配置应唯一覆盖继承值：value=%q count=%d", values["MIMI_MANAGED_ENV_TEST"], counts["MIMI_MANAGED_ENV_TEST"])
	}
	if values["CODEX_HOME"] != "/configured/codex" || counts["CODEX_HOME"] != 1 {
		t.Fatalf("CODEX_HOME 必须沿用显式配置且不重复：value=%q count=%d", values["CODEX_HOME"], counts["CODEX_HOME"])
	}
}
