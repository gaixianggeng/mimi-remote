package setup

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"time"
	"unicode"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

// passiveFileAccount only consults the standard private, file-backed account.
// A missing, expired or unsupported credential is unknown. Neither absence nor
// parse failure proves that the user signed out (the CLI may use a keychain).
func passiveFileAccount(cfg config.Config, name string) string {
	home, err := os.UserHomeDir()
	if err != nil || !filepath.IsAbs(home) {
		return ""
	}
	var dir, file string
	switch name {
	case "codex":
		dir = filepath.Join(home, ".codex")
		effective, local := cfg.EffectiveLocalCodexHome()
		if !local || effective != dir || accountHomeOverridden(cfg.Codex.Env, home) {
			return ""
		}
		file = "auth.json"
	case "claude":
		dir = filepath.Join(home, ".claude")
		if accountHomeOverridden(cfg.Claude.Env, home) || !claudeUsesFileAccount(cfg.Claude.Env, dir) {
			return ""
		}
		file = ".credentials.json"
	default:
		return ""
	}
	// Do not enter a symlink to a custom or protected directory while polling.
	// A group-writable executable configuration directory is also unsuitable as
	// account evidence. The file reader checks the actual opened file separately.
	info, err := os.Lstat(dir)
	if err != nil || !info.IsDir() || runtime.GOOS != "windows" && info.Mode().Perm()&0022 != 0 {
		return ""
	}
	raw, err := config.ReadPrivatePreflightFile(filepath.Join(dir, file), 64<<10)
	if err != nil {
		return ""
	}
	defer clear(raw)
	if name == "codex" && currentCodexFileAccount(raw, time.Now()) || name == "claude" && currentClaudeFileAccount(raw, time.Now()) {
		return "connected"
	}
	return ""
}

func accountHomeOverridden(env map[string]string, home string) bool {
	for key, value := range env {
		if (strings.EqualFold(key, "HOME") || strings.EqualFold(key, "USERPROFILE")) && value != home {
			return true
		}
	}
	return false
}

func claudeUsesFileAccount(env map[string]string, dir string) bool {
	for key, value := range env {
		if value == "" {
			continue
		}
		switch strings.ToUpper(key) {
		case "CLAUDE_CONFIG_DIR":
			if value != dir {
				return false
			}
		case "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY":
			// These modes use another credential or provider; do not borrow the
			// default subscription's evidence for them.
			return false
		}
	}
	return true
}

func currentCodexFileAccount(raw []byte, now time.Time) bool {
	var doc struct {
		AuthMode string `json:"auth_mode"`
		Tokens   struct {
			AccessToken string `json:"access_token"`
		} `json:"tokens"`
	}
	if json.Unmarshal(raw, &doc) != nil || doc.AuthMode != "chatgpt" {
		return false
	}
	parts := strings.Split(doc.Tokens.AccessToken, ".")
	if len(parts) != 3 {
		return false
	}
	header, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return false
	}
	var meta struct{ Alg string }
	if json.Unmarshal(header, &meta) != nil || strings.TrimSpace(meta.Alg) == "" || strings.EqualFold(meta.Alg, "none") {
		return false
	}
	signature, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || len(signature) == 0 {
		return false
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return false
	}
	// This reads expiry evidence in an owner-controlled CLI file. Only the
	// provider can establish acceptance of the credential.
	var claims struct{ Exp, Nbf int64 }
	return json.Unmarshal(payload, &claims) == nil && claims.Exp > now.Unix() && claims.Nbf <= now.Unix()
}

func currentClaudeFileAccount(raw []byte, now time.Time) bool {
	var doc struct {
		OAuth struct {
			AccessToken string   `json:"accessToken"`
			ExpiresAt   int64    `json:"expiresAt"`
			Scopes      []string `json:"scopes"`
		} `json:"claudeAiOauth"`
	}
	if json.Unmarshal(raw, &doc) != nil {
		return false
	}
	oauth := doc.OAuth
	return oauth.AccessToken != "" && !strings.ContainsFunc(oauth.AccessToken, func(r rune) bool { return unicode.IsSpace(r) || unicode.IsControl(r) }) &&
		oauth.ExpiresAt > now.UnixMilli() && slices.Contains(oauth.Scopes, "user:inference")
}
