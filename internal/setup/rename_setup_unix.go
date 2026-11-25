//go:build !windows

package setup

import "os"

func renameSetupFile(source, destination string) error { return os.Rename(source, destination) }

func publishSetupCompanion(stage, path string, ops setupFileTransactionOps) error {
	return ops.link(stage, path)
}
