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

func TestRegistryAllowsMissingRegisteredProjectAsReadOnlyMissingState(t *testing.T) {
	parent := t.TempDir()
	missingDir := filepath.Join(parent, "moved-project")
	registry, err := NewRegistry([]config.ProjectConfig{{ID: "moved", Name: "Moved", Path: missingDir}})
	if err != nil {
		t.Fatalf("已登记目录缺失时不应阻止网关启动：%v", err)
	}
	project, ok := registry.Get("moved")
	if !ok {
		t.Fatal("缺失目录项目应保留在注册表中以便历史回溯")
	}
	if !project.Missing {
		t.Fatalf("期望 Missing=true，实际 %+v", project)
	}
	realParent, err := filepath.EvalSymlinks(parent)
	if err != nil {
		t.Fatal(err)
	}
	wantReal := filepath.Join(realParent, "moved-project")
	if project.RealPath != wantReal {
		t.Fatalf("缺失项目规范路径不符：got=%q want=%q", project.RealPath, wantReal)
	}
	// 非目录文件与悬空符号链接仍必须拒绝。
	filePath := filepath.Join(parent, "not-a-dir.txt")
	if err := os.WriteFile(filePath, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := NewRegistry([]config.ProjectConfig{{ID: "file", Name: "File", Path: filePath}}); err == nil {
		t.Fatal("普通文件作为项目路径必须继续拒绝")
	}
	dangling := filepath.Join(parent, "dangling-link")
	if err := os.Symlink(filepath.Join(parent, "does-not-exist-target"), dangling); err != nil {
		t.Fatal(err)
	}
	if _, err := NewRegistry([]config.ProjectConfig{{ID: "link", Name: "Link", Path: dangling}}); err == nil {
		t.Fatal("悬空符号链接作为项目路径必须继续拒绝")
	}

	// C14 round3: 恢复已登记目录后，无需重启网关，List() 与 Get() 应即时刷新 Missing=false；
	// 再次移走后应即时刷新 Missing=true。
	if err := os.MkdirAll(missingDir, 0o755); err != nil {
		t.Fatalf("restore missingDir: %v", err)
	}
	restored, ok := registry.Get("moved")
	if !ok || restored.Missing {
		t.Fatalf("目录恢复后 Get 应立即清除 Missing，实际 %+v ok=%v", restored, ok)
	}
	listed := registry.List()
	if len(listed) != 1 || listed[0].Missing {
		t.Fatalf("目录恢复后 List 应立即清除 Missing，实际 %+v", listed)
	}

	if err := os.RemoveAll(missingDir); err != nil {
		t.Fatalf("remove missingDir again: %v", err)
	}
	missingAgain, ok := registry.Get("moved")
	if !ok || !missingAgain.Missing {
		t.Fatalf("目录再次移走后 Get 应立即报告 Missing=true，实际 %+v ok=%v", missingAgain, ok)
	}
}
