package setup

import (
	"bytes"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestWorkspacePreservesIdentityAndRestoresOnlyRoots(t *testing.T) {
	path := moduleTestConfig(t)
	root := t.TempDir()
	result, err := ConfigureWorkspace(path, root)
	if err != nil {
		t.Fatal(err)
	}
	resolved, _ := filepath.EvalSymlinks(root)
	cfg := moduleConfig(t, path)
	if !result.Changed || !reflect.DeepEqual(cfg.ScanRoots, []string{resolved}) || !reflect.DeepEqual(cfg.BrowseRoots, []string{resolved}) {
		t.Fatalf("selected roots not applied: %+v", result)
	}
	assertModuleUnknowns(t, path)
	// A change in another module survives rollback of the directory selection.
	if _, err := ConfigureNetworkAccess(path, "tailscale", false); err != nil {
		t.Fatal(err)
	}
	if _, err := RestoreWorkspace(path, result); err != nil {
		t.Fatal(err)
	}
	cfg = moduleConfig(t, path)
	if len(cfg.ScanRoots) != 0 || len(cfg.BrowseRoots) != 0 || cfg.TailscaleAccessEnabled() {
		t.Fatal("rollback lost original roots or a newer module change")
	}
	assertModuleUnknowns(t, path)
}

func TestWorkspaceRejectsInvalidRootsAndStaleRollback(t *testing.T) {
	path := moduleTestConfig(t)
	original, _ := os.ReadFile(path)
	for _, root := range []string{"relative", filepath.Join(t.TempDir(), "missing"), path} {
		if _, err := ConfigureWorkspace(path, root); err == nil {
			t.Fatalf("invalid directory accepted: %s", root)
		}
		current, _ := os.ReadFile(path)
		if !bytes.Equal(original, current) {
			t.Fatal("failed operation changed configuration")
		}
	}
	first, err := ConfigureWorkspace(path, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := ConfigureWorkspace(path, t.TempDir()); err != nil {
		t.Fatal(err)
	}
	current, _ := os.ReadFile(path)
	if _, err := RestoreWorkspace(path, first); err == nil {
		t.Fatal("stale rollback overwrote newer roots")
	}
	after, _ := os.ReadFile(path)
	if !bytes.Equal(current, after) {
		t.Fatal("rejected rollback changed configuration")
	}
}
