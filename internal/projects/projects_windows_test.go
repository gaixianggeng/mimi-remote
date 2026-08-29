//go:build windows

package projects

import (
	"path/filepath"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestFindByPathMatchesWindowsExtendedLocalPath(t *testing.T) {
	root := t.TempDir()
	registry, err := NewRegistry([]config.ProjectConfig{{ID: "demo", Name: "Demo", Path: root}})
	if err != nil {
		t.Fatal(err)
	}

	namespacedChild := `\\?\` + filepath.Join(root, "Sources", "Missing.swift")
	project, ok := registry.FindByPath(namespacedChild)
	if !ok || project.ID != "demo" {
		t.Fatalf("extended local path should match the configured project: %+v ok=%v", project, ok)
	}
}

func TestFindByPathDoesNotExpandAllowlistForWindowsNamespaces(t *testing.T) {
	root := t.TempDir()
	registry, err := NewRegistry([]config.ProjectConfig{{ID: "demo", Name: "Demo", Path: root}})
	if err != nil {
		t.Fatal(err)
	}

	outside := filepath.Join(t.TempDir(), "outside")
	tests := map[string]string{
		"local path outside project": `\\?\` + outside,
		"local traversal outside":    `\\?\` + filepath.Join(root, "..", "escaped"),
		"extended UNC":               `\\?\UNC\server\share\project`,
		"Win32 device":               `\\.\C:\project`,
		"NT object manager":          `\??\C:\project`,
		"GLOBALROOT":                 `\\?\GLOBALROOT\Device\HarddiskVolume1\project`,
		"volume GUID":                `\\?\Volume{00000000-0000-0000-0000-000000000000}\project`,
		"drive relative namespace":   `\\?\C:relative\project`,
		"missing volume namespace":   `\\?\\project`,
		"ordinary UNC":               `\\server\share\project`,
	}
	for name, path := range tests {
		t.Run(name, func(t *testing.T) {
			if project, ok := registry.FindByPath(path); ok {
				t.Fatalf("path outside the local project allowlist matched %+v", project)
			}
		})
	}
}

func TestPathForProjectMatchRejectsUnsafeWindowsNamespaces(t *testing.T) {
	tests := []string{
		`\\?\UNC\server\share\project`,
		`\\?\GLOBALROOT\Device\HarddiskVolume1\project`,
		`\\?\Volume{00000000-0000-0000-0000-000000000000}\project`,
		`\\?\C:relative\project`,
		`\\.\C:\project`,
		`\??\C:\project`,
	}
	for _, path := range tests {
		t.Run(path, func(t *testing.T) {
			if normalized, ok := pathForProjectMatch(path); ok {
				t.Fatalf("unsafe namespace normalized to %q", normalized)
			}
		})
	}
}
