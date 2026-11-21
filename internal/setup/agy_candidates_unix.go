//go:build !windows

package setup

import (
	"os"
	"path/filepath"
	"strings"
)

func agyExecutableCandidates(configured string) []string {
	candidates := []string{strings.TrimSpace(configured), "agy"}
	if home, err := os.UserHomeDir(); err == nil {
		candidates = append(candidates,
			filepath.Join(home, ".local", "bin", "agy"),
		)
	}
	candidates = append(candidates,
		"/opt/homebrew/bin/agy",
		"/usr/local/bin/agy",
	)
	return candidates
}
