package setup

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/config/configtest"
)

func TestPreflightFileCredentialMetadata(t *testing.T) {
	now := time.Unix(2000000000, 0)
	fixtureJSON := func(v any) []byte {
		raw, err := json.Marshal(v)
		if err != nil {
			t.Fatal(err)
		}
		return raw
	}
	part := func(v any) string { return base64.RawURLEncoding.EncodeToString(fixtureJSON(v)) }
	access := func(alg string, exp, nbf int64) string {
		return part(map[string]string{"alg": alg}) + "." + part(map[string]int64{"exp": exp, "nbf": nbf}) + "." + base64.RawURLEncoding.EncodeToString([]byte("fixture"))
	}
	codex := func(mode, token string) []byte {
		return fixtureJSON(map[string]any{"auth_mode": mode, "tokens": map[string]string{"access_token": token}})
	}
	valid := access("RS256", now.Unix()+60, 0)
	for _, tc := range []struct {
		name, mode, token string
		ok                bool
	}{
		{"current", "chatgpt", valid, true}, {"expired", "chatgpt", access("RS256", now.Unix(), 0), false},
		{"future", "chatgpt", access("RS256", now.Unix()+60, now.Unix()+20), false},
		{"unsigned", "chatgpt", access("none", now.Unix()+60, 0), false}, {"opaque", "chatgpt", "fixture", false},
		{"other mode", "apikey", valid, false}, {"absent", "", "", false},
	} {
		t.Run("codex/"+tc.name, func(t *testing.T) {
			if currentCodexFileAccount(codex(tc.mode, tc.token), now) != tc.ok {
				t.Error("unexpected file evidence")
			}
		})
	}
	claude := func(token string, expires int64, scopes []string) []byte {
		return fixtureJSON(map[string]any{"claudeAiOauth": map[string]any{"accessToken": token, "expiresAt": expires, "scopes": scopes}})
	}
	for _, tc := range []struct {
		name, token, scope string
		expires            int64
		ok                 bool
	}{
		{"current", "fixture", "user:inference", now.UnixMilli() + 60000, true},
		{"expired", "fixture", "user:inference", now.UnixMilli(), false},
		{"missing expiry", "fixture", "user:inference", 0, false},
		{"missing token", "", "user:inference", now.UnixMilli() + 60000, false},
		{"profile only", "fixture", "user:profile", now.UnixMilli() + 60000, false},
	} {
		t.Run("claude/"+tc.name, func(t *testing.T) {
			if currentClaudeFileAccount(claude(tc.token, tc.expires, []string{tc.scope}), now) != tc.ok {
				t.Error("unexpected file evidence")
			}
		})
	}
}

func TestPreflightFileAccountReadsOnlyStandardPrivateFile(t *testing.T) {
	home := preflightSandbox(t)
	t.Setenv("CODEX_HOME", "")
	cfg := config.Config{}
	cfg.AppServer.Transport = "local"
	if config.SupportsManagedAppServer() {
		cfg.AppServer = config.DefaultManagedAppServerConfig()
	}
	cfg.Claude.Env = map[string]string{}
	cliDir := filepath.Join(home, ".claude")
	if err := os.Mkdir(cliDir, 0700); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(cliDir, ".credentials.json")
	body := []byte(`{"claudeAiOauth":{"accessToken":"fixture","expiresAt":4102444800000,"scopes":["user:inference"]}}`)
	configtest.CreatePrivateFile(t, file, body)
	if got := passiveFileAccount(cfg, "claude"); got != "connected" {
		t.Errorf("fresh standard Claude file returned %q", got)
	}
	for _, key := range []string{"CLAUDE_CONFIG_DIR", "HOME", "ANTHROPIC_API_KEY", "CLAUDE_CODE_USE_VERTEX"} {
		cfg.Claude.Env[key] = "custom"
		if got := passiveFileAccount(cfg, "claude"); got != "" {
			t.Errorf("redirected/other credentials (%s) returned %q", key, got)
		}
		delete(cfg.Claude.Env, key)
	}
	// Keychain-only and unknown runtimes need a daemon observation.
	for _, name := range []string{"agy", "deepseek", "other"} {
		if got := passiveFileAccount(cfg, name); got != "" {
			t.Errorf("unexpected %s observation %q", name, got)
		}
	}
	codexDir := filepath.Join(home, ".codex")
	if err := os.Mkdir(codexDir, 0700); err != nil {
		t.Fatal(err)
	}
	enc := base64.RawURLEncoding.EncodeToString
	jwt := enc([]byte(`{"alg":"RS256"}`)) + "." + enc([]byte(`{"exp":4102444800}`)) + "." + enc([]byte("fixture"))
	raw, err := json.Marshal(map[string]any{"auth_mode": "chatgpt", "tokens": map[string]string{"access_token": jwt}})
	if err != nil {
		t.Fatal(err)
	}
	configtest.CreatePrivateFile(t, filepath.Join(codexDir, "auth.json"), raw)
	if got := passiveFileAccount(cfg, "codex"); got != "connected" {
		t.Errorf("valid standard Codex evidence returned %q", got)
	}
	cfg.Codex.Env = map[string]string{"codex_home": cliDir}
	want := "connected"
	if runtime.GOOS == "windows" {
		want = ""
	}
	if got := passiveFileAccount(cfg, "codex"); got != want {
		t.Errorf("lowercase Codex home returned %q, want %q", got, want)
	}
	cfg.Codex.Env = nil
	t.Setenv("CODEX_HOME", cliDir)
	if got := passiveFileAccount(cfg, "codex"); got != "" {
		t.Errorf("custom Codex home borrowed default evidence: %q", got)
	}
	t.Setenv("CODEX_HOME", "")
	cfg.AppServer.Transport = "ssh"
	if got := passiveFileAccount(cfg, "codex"); got != "" {
		t.Errorf("remote transport borrowed local evidence: %q", got)
	}
	if runtime.GOOS != "windows" {
		if err := os.Chmod(file, 0644); err != nil {
			t.Fatal(err)
		}
		if got := passiveFileAccount(cfg, "claude"); got != "" {
			t.Errorf("non-private file returned %q", got)
		}
		if err := os.Chmod(file, 0600); err != nil {
			t.Fatal(err)
		}
		elsewhere := filepath.Join(home, "documents-fixture")
		if err := os.Rename(cliDir, elsewhere); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(elsewhere, cliDir); err != nil {
			t.Fatal(err)
		}
		if got := passiveFileAccount(cfg, "claude"); got != "" {
			t.Errorf("symlinked directory returned %q", got)
		}
	}
}

func TestWindowsCodexHomeRedirected(t *testing.T) {
	const standard = `C:\fixture\.codex`
	for _, tc := range []struct {
		name       string
		env        map[string]string
		redirected bool
	}{
		{"standard", map[string]string{"Codex_Home": standard}, false},
		{"another drive", map[string]string{"codex_home": `D:\fixture\.codex`}, true},
		{"conflicting spellings", map[string]string{"CODEX_HOME": standard, "Codex_Home": `\\fixture.invalid\other`}, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := windowsCodexHomeRedirected(tc.env, standard); got != tc.redirected {
				t.Errorf("redirected = %v, want %v", got, tc.redirected)
			}
		})
	}
}
