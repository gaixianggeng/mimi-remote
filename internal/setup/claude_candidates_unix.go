//go:build !windows

package setup

import (
	"os"
	"path/filepath"
	"strings"
)

func claudeExecutableCandidates(configured string) []string {
	candidates := []string{strings.TrimSpace(configured), "claude"}
	if home, err := os.UserHomeDir(); err == nil {
		candidates = append(candidates,
			filepath.Join(home, ".local", "bin", "claude"),
			filepath.Join(home, ".npm-global", "bin", "claude"),
		)
	}
	return candidates
}
