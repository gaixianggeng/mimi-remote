//go:build !darwin && !linux && !windows

package setup

import "os"

func renameNewSetupFile(old, new string) error {
	if err := os.Link(old, new); err != nil {
		return err
	}
	return os.Remove(old)
}
