package projects

import (
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestRegistryLoadsValidProject(t *testing.T) {
	dir := t.TempDir()
	registry, err := NewRegistry([]config.ProjectConfig{{ID: "demo", Name: "Demo", Path: dir}})
	if err != nil {
		t.Fatal(err)
	}
	project, ok := registry.Get("demo")
	if !ok {
		t.Fatal("期望能按 ID 查询项目")
	}
	if project.RealPath == "" || !filepath.IsAbs(project.Path) {
		t.Fatalf("路径未正确规范化：%+v", project)
	}
}

func TestRegistryRejectsInvalidID(t *testing.T) {
	_, err := NewRegistry([]config.ProjectConfig{{ID: "../bad", Name: "bad", Path: t.TempDir()}})
	if err == nil {
		t.Fatal("期望非法项目 ID 被拒绝")
	}
}

func TestFindByPathMatchesNestedProjectAndPrefersDeepest(t *testing.T) {
	root := t.TempDir()
	child := filepath.Join(root, "app")
	nested := filepath.Join(child, "Sources")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatal(err)
	}
	registry, err := NewRegistry([]config.ProjectConfig{
		{ID: "workspace", Name: "Workspace", Path: root},
		{ID: "app", Name: "App", Path: child},
	})
	if err != nil {
		t.Fatal(err)
	}

	project, ok := registry.FindByPath(nested)
	if !ok {
		t.Fatal("期望子目录能匹配到项目")
	}
	if project.ID != "app" {
		t.Fatalf("期望优先匹配最深项目，实际 %+v", project)
	}

	missingNested := filepath.Join(child, "Generated", "Missing.swift")
	project, ok = registry.FindByPath(missingNested)
	if !ok {
		t.Fatal("不存在的项目子路径也应通过字符串父路径匹配到项目")
	}
	if project.ID != "app" {
		t.Fatalf("不存在的子路径也应优先匹配最深项目，实际 %+v", project)
	}
}

func TestFindByPathCachesMatchesAndBoundsMisses(t *testing.T) {
	root := t.TempDir()
	nested := filepath.Join(root, "Sources")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatal(err)
	}
	registry, err := NewRegistry([]config.ProjectConfig{{ID: "demo", Name: "Demo", Path: root}})
	if err != nil {
		t.Fatal(err)
	}

	project, ok := registry.FindByPath(nested)
	if !ok || project.ID != "demo" {
		t.Fatalf("期望首次路径匹配成功：%+v ok=%v", project, ok)
	}
	cacheKey, err := filepath.Abs(nested)
	if err != nil {
		t.Fatal(err)
	}
	cacheKey = filepath.Clean(cacheKey)
	registry.cacheMu.Lock()
	entry, hit := registry.pathMatchCache[cacheKey]
	if !hit {
		registry.cacheMu.Unlock()
		t.Fatal("首次匹配后应写入路径缓存")
	}
	entry.project.Name = "Cached Demo"
	registry.pathMatchCache[cacheKey] = entry
	registry.cacheMu.Unlock()

	project, ok = registry.FindByPath(nested)
	if !ok || project.Name != "Cached Demo" {
		t.Fatalf("重复路径应直接命中缓存，实际 %+v ok=%v", project, ok)
	}

	outsideRoot := filepath.Join(t.TempDir(), "outside")
	for index := 0; index < maxPathMatchCacheEntries+16; index++ {
		if project, ok := registry.FindByPath(filepath.Join(outsideRoot, "missing-"+strconv.Itoa(index))); ok {
			t.Fatalf("无关路径不应匹配到项目：%+v", project)
		}
	}
	registry.cacheMu.Lock()
	cacheSize := len(registry.pathMatchCache)
	registry.cacheMu.Unlock()
	if cacheSize > maxPathMatchCacheEntries {
		t.Fatalf("路径匹配缓存应有硬上限，实际 %d", cacheSize)
	}
}
