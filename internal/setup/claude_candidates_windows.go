package setup

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func claudeExecutableCandidates(configured string) []string {
	rawCandidates := []string{strings.TrimSpace(configured)}
	if resolved, err := exec.LookPath("claude"); err == nil {
		rawCandidates = append(rawCandidates, resolved)
	}
	if home, err := os.UserHomeDir(); err == nil {
		rawCandidates = append(rawCandidates,
			filepath.Join(home, ".local", "bin", "claude.exe"),
			filepath.Join(home, "AppData", "Roaming", "npm", "node_modules", "@anthropic-ai", "claude-code", "bin", "claude.exe"),
		)
	}
	if resolved, err := exec.LookPath("claude.exe"); err == nil {
		rawCandidates = append(rawCandidates, resolved)
	}

	candidates := make([]string, 0, len(rawCandidates))
	for _, candidate := range rawCandidates {
		if native, ok := nativeClaudeExecutableCandidate(candidate); ok {
			candidates = append(candidates, native)
		}
	}
	return candidates
}

func nativeClaudeExecutableCandidate(candidate string) (string, bool) {
	candidate = strings.TrimSpace(candidate)
	if candidate == "" {
		return "", false
	}
	resolved := candidate
	if !filepath.IsAbs(resolved) {
		path, err := exec.LookPath(resolved)
		if err != nil {
			return "", false
		}
		resolved = path
	}
	switch strings.ToLower(filepath.Ext(resolved)) {
	case ".exe":
		return filepath.Clean(resolved), true
	case ".cmd", ".bat", ".ps1", "":
		native := filepath.Join(
			filepath.Dir(resolved),
			"node_modules",
			"@anthropic-ai",
			"claude-code",
			"bin",
			"claude.exe",
		)
		info, err := os.Stat(native)
		if err == nil && info.Mode().IsRegular() {
			return filepath.Clean(native), true
		}
	}
	return "", false
}
