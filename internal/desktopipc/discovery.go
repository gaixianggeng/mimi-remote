package desktopipc

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type DesktopInfo struct {
	Installed bool
	Running   bool
	Version   string
	Build     string
	Bundle    string
	Socket    string
}

func InspectDesktop(codexBin string, env map[string]string) (DesktopInfo, error) {
	return inspectDesktop(codexBin, env)
}

func resolveCodexHome(env map[string]string) (string, error) {
	home := strings.TrimSpace(env["CODEX_HOME"])
	if home == "" {
		userHome, err := os.UserHomeDir()
		if err != nil {
			return "", fmt.Errorf("resolve CODEX_HOME: %w", err)
		}
		home = filepath.Join(userHome, ".codex")
	} else if strings.HasPrefix(home, "~/") {
		userHome, err := os.UserHomeDir()
		if err != nil {
			return "", fmt.Errorf("resolve CODEX_HOME: %w", err)
		}
		home = filepath.Join(userHome, strings.TrimPrefix(home, "~/"))
	}
	if !filepath.IsAbs(home) {
		return "", fmt.Errorf("CODEX_HOME must be absolute")
	}
	return filepath.Clean(home), nil
}
