//go:build !windows

package setup

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestSetupRechecksModeBeforeReplacingConfig(t *testing.T) {
	clearSetupEnv(t)
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	opts := atomicSetupOptions(t, path, false)
	if _, err := Run(t.Context(), opts); err != nil {
		t.Fatal(err)
	}
	old := readPublicationBytes(t, path)
	opts.ScanRoot = t.TempDir()
	ops := defaultSetupFileTransactionOps()
	moveNew := ops.renameNew
	ops.renameNew = func(from, to string) error {
		if err := moveNew(from, to); err != nil {
			return err
		}
		if to == config.SetupJournalPath(path) {
			return os.Chmod(path, 0400)
		}
		return nil
	}
	ops.rename = func(string, string) error {
		t.Fatal("replaced config after concurrent chmod")
		return nil
	}
	_, err := runWithFileOps(t.Context(), opts, ops)
	requirePublicationError(t, err, "config_concurrent_change")
	assertFileBytesAndMode(t, path, old, 0400)
	record := readPublicationRecord(t, path)
	stage := filepath.Join(dir, record.ConfigStage)
	if !filePresent(stage) {
		t.Fatal("lost stage on conflict")
	}
	if _, err := Run(t.Context(), opts); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0400 {
		t.Fatalf("retry lost narrowed mode: %v %v", info, err)
	}
	assertMissingPath(t, stage)
	assertMissingPath(t, config.SetupJournalPath(path))
}

func TestRollbackUsesModeOfPublishedConfig(t *testing.T) {
	clearSetupEnv(t)
	path := filepath.Join(t.TempDir(), "config.json")
	opts := atomicSetupOptions(t, path, false)
	if _, err := Run(t.Context(), opts); err != nil {
		t.Fatal(err)
	}
	old := readPublicationBytes(t, path)
	// Creation starts with 0400, then permission copying restores the owner's
	// execute bit. Rollback must compare with the actual published mode.
	if err := os.Chmod(path, 0500); err != nil {
		t.Fatal(err)
	}
	opts.ScanRoot = t.TempDir()
	fault := errors.New("injected directory sync failure")
	_, err := runWithFileOps(t.Context(), opts, failingSetupFileOps(path, "directory-fsync", fault))
	if !errors.Is(err, fault) {
		t.Fatalf("expected directory sync failure, got %v", err)
	}
	assertFileBytesAndMode(t, path, old, 0500)
	assertMissingPath(t, config.SetupJournalPath(path))
}
