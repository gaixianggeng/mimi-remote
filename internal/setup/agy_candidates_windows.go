package setup

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func agyExecutableCandidates(configured string) []string {
	candidates := []string{strings.TrimSpace(configured)}
	if resolved, err := exec.LookPath("agy"); err == nil {
		candidates = append(candidates, resolved)
	}
	if resolved, err := exec.LookPath("agy.exe"); err == nil {
		candidates = append(candidates, resolved)
	}
	if home, err := os.UserHomeDir(); err == nil {
		candidates = append(candidates,
			filepath.Join(home, ".local", "bin", "agy.exe"),
			filepath.Join(home, "AppData", "Local", "Programs", "Antigravity", "bin", "agy.exe"),
		)
	}
	return candidates
}
