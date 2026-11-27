package projects

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestRegistryInMemoryLookupsAvoidDiskAndCacheMutation(t *testing.T) {
	root := t.TempDir()
	projectDir := filepath.Join(root, "alpha")
	if err := os.MkdirAll(projectDir, 0o755); err != nil {
		t.Fatal(err)
	}
	realProjectDir, err := filepath.EvalSymlinks(projectDir)
	if err != nil {
		t.Fatal(err)
	}

	reg, err := NewRegistry([]config.ProjectConfig{
		{ID: "alpha", Name: "Alpha", Path: projectDir},
	})
	if err != nil {
		t.Fatalf("NewRegistry failed: %v", err)
	}

	// Remove the directory on disk after registry creation.
	if err := os.RemoveAll(projectDir); err != nil {
		t.Fatal(err)
	}

	refreshCalls := 0
	prevHook := onRefreshProjectAvailabilityForTest
	onRefreshProjectAvailabilityForTest = func(Project) {
		refreshCalls++
	}
	t.Cleanup(func() {
		onRefreshProjectAvailabilityForTest = prevHook
	})

	got, ok := reg.GetCached("alpha")
	if !ok || got.ID != "alpha" || got.Missing {
		t.Fatalf("GetCached should return pure-memory snapshot without disk refresh: ok=%v got=%+v", ok, got)
	}
	if list := reg.ListCached(); len(list) != 1 || list[0].ID != "alpha" {
		t.Fatalf("ListCached unexpected result: %+v", list)
	}

	subPath := filepath.Join(realProjectDir, "nested", "dir")
	matched, ok := reg.FindByCanonicalPathInMemory(subPath)
	if !ok || matched.ID != "alpha" {
		t.Fatalf("FindByCanonicalPathInMemory failed: ok=%v got=%+v", ok, matched)
	}
	if _, ok := reg.FindByCanonicalPathInMemory(filepath.Join(root, "outside")); ok {
		t.Fatal("FindByCanonicalPathInMemory should not match outside path")
	}
	if _, ok := reg.FindByCanonicalPathInMemory("relative/path"); ok {
		t.Fatal("FindByCanonicalPathInMemory must reject relative path")
	}
	if refreshCalls != 0 {
		t.Fatalf("in-memory queries must not call refreshProjectAvailability, got %d", refreshCalls)
	}

	// Ensure FindByCanonicalPathInMemory never wrote or evicted pathMatchCache.
	reg.cacheMu.Lock()
	cacheLen := len(reg.pathMatchCache)
	reg.cacheMu.Unlock()
	if cacheLen != 0 {
		t.Fatalf("FindByCanonicalPathInMemory must not mutate pathMatchCache, got len=%d", cacheLen)
	}

	// Control check: Get() still refreshes availability and observes deleted dir.
	live, ok := reg.Get("alpha")
	if !ok || !live.Missing || refreshCalls != 1 {
		t.Fatalf("Get control check failed: ok=%v missing=%v calls=%d", ok, live.Missing, refreshCalls)
	}
}

func TestFindByPathVerifyingMatchSkipsUnrelatedProjects(t *testing.T) {
	root := t.TempDir()
	dirA := filepath.Join(root, "alpha")
	dirB := filepath.Join(root, "beta")
	if err := os.MkdirAll(dirA, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(dirB, 0o755); err != nil {
		t.Fatal(err)
	}
	reg, err := NewRegistry([]config.ProjectConfig{
		{ID: "alpha", Name: "Alpha", Path: dirA},
		{ID: "beta", Name: "Beta", Path: dirB},
	})
	if err != nil {
		t.Fatal(err)
	}

	probed := map[string]int{}
	prevHook := onRefreshProjectAvailabilityForTest
	onRefreshProjectAvailabilityForTest = func(p Project) {
		probed[p.ID]++
	}
	t.Cleanup(func() { onRefreshProjectAvailabilityForTest = prevHook })

	matched, ok := reg.FindByPathVerifyingMatch(dirA)
	if !ok || matched.ID != "alpha" {
		t.Fatalf("expected alpha match, got ok=%v %+v", ok, matched)
	}
	if probed["alpha"] != 1 || probed["beta"] != 0 {
		t.Fatalf("FindByPathVerifyingMatch must probe ONLY matched project alpha, got %v", probed)
	}
	// Outside path must probe zero projects.
	if _, ok := reg.FindByPathVerifyingMatch(filepath.Join(root, "outside")); ok {
		t.Fatal("outside path must not match")
	}
	if probed["beta"] != 0 {
		t.Fatalf("outside path must not probe unrelated projects, got %v", probed)
	}
}
