package setup

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"slices"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestResolveCodexBinFallsBackFromStaleConfiguredPath(t *testing.T) {
	f := newDiscoveryFixture(t)
	dir := t.TempDir()
	path := filepath.Join(dir, "codex")
	f.env["PATH"] = dir
	f.add(t, path, "codex-cli 0.155.0")
	old := filepath.Join(t.TempDir(), "codex")
	resolved, err := f.repairCodex(context.Background(), RuntimeRequest{Name: "codex", Pin: old})
	if err != nil || resolved.Path != path {
		t.Fatalf("missing pin: %+v, %v", resolved, err)
	}
	f.add(t, old, "codex-cli 0.140.0")
	resolved, err = f.repairCodex(context.Background(), RuntimeRequest{Name: "codex", Pin: old})
	if !errors.Is(err, ErrRuntimeIncompatible) || resolved.Path != old || resolved.Source != "pin" {
		t.Fatalf("existing incompatible pin: %+v, %v", resolved, err)
	}
}

func TestResolveCodexBinFallsBackToDesktopApp(t *testing.T) {
	const embedded = "/Applications/ChatGPT.app/Contents/Resources/codex"
	f := newDiscoveryFixture(t)
	f.add(t, embedded, "codex-cli 0.155.0")
	resolved, err := f.repairCodex(context.Background(), RuntimeRequest{Name: "codex", Pin: "/deleted/codex"})
	if err != nil || resolved.Path != embedded {
		t.Fatalf("repair = %+v, %v", resolved, err)
	}
}

func TestDarwinCodexCandidatesCoverEmbeddedChatGPTAndCodexApps(t *testing.T) {
	home := filepath.Join(string(filepath.Separator), "Users", "example")
	candidates := darwinCodexCandidates(home)
	for _, expected := range []string{
		"/opt/homebrew/bin/codex",
		"/usr/local/bin/codex",
		filepath.Join(home, ".local", "bin", "codex"),
		filepath.Join(home, ".npm-global", "bin", "codex"),
		"/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
		"/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
		"/Applications/ChatGPT.app/Contents/Resources/codex",
		"/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
		"/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
		"/Applications/Codex.app/Contents/Resources/codex",
		filepath.Join(home, "Applications", "ChatGPT.app", "Contents", "Resources", "codex-cli", "bin", "codex"),
		filepath.Join(home, "Applications", "Codex.app", "Contents", "Resources", "codex-cli", "bin", "codex"),
	} {
		if !slices.Contains(candidates, expected) {
			t.Fatalf("macOS Codex fallback 缺少 %q：%v", expected, candidates)
		}
	}

	const embedded = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"
	f := newDiscoveryFixture(t)
	f.add(t, embedded, "codex-cli 0.155.0")
	resolved, err := f.Resolve(context.Background(), RuntimeRequest{Name: "codex"})
	if err != nil || resolved.Path != embedded {
		t.Fatalf("PATH-empty selection: %+v, %v", resolved, err)
	}
}

func TestResolveCodexBinDarwinPrecedenceWhenMultipleCandidatesExist(t *testing.T) {
	home := filepath.Join(string(filepath.Separator), "Users", "example")
	candidates := darwinCodexCandidates(home)

	systemChatGPT := "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"
	userChatGPT := filepath.Join(home, "Applications", "ChatGPT.app", "Contents", "Resources", "codex-cli", "bin", "codex")
	userCodexLegacy := filepath.Join(home, "Applications", "Codex.app", "Contents", "Resources", "codex")
	homebrewAppleSilicon := "/opt/homebrew/bin/codex"
	homebrewIntel := "/usr/local/bin/codex"
	userLocal := filepath.Join(home, ".local", "bin", "codex")
	pathCodex := "/custom/path/bin/codex"
	explicitCodex := "/explicit/config/bin/codex"

	desktopApps := []string{
		"/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
		"/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
		"/Applications/ChatGPT.app/Contents/Resources/codex",
		"/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
		"/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
		"/Applications/Codex.app/Contents/Resources/codex",
		filepath.Join(home, "Applications", "ChatGPT.app", "Contents", "Resources", "codex-cli", "bin", "codex"),
		filepath.Join(home, "Applications", "ChatGPT.app", "Contents", "Resources", "codex-cli", "CodexCLI.app", "Contents", "MacOS", "codex"),
		filepath.Join(home, "Applications", "ChatGPT.app", "Contents", "Resources", "codex"),
		filepath.Join(home, "Applications", "Codex.app", "Contents", "Resources", "codex-cli", "bin", "codex"),
		filepath.Join(home, "Applications", "Codex.app", "Contents", "Resources", "codex-cli", "CodexCLI.app", "Contents", "MacOS", "codex"),
		filepath.Join(home, "Applications", "Codex.app", "Contents", "Resources", "codex"),
	}
	installerFallbacks := []string{
		homebrewAppleSilicon,
		homebrewIntel,
		userLocal,
		filepath.Join(home, ".npm-global", "bin", "codex"),
		filepath.Join(home, ".local", "share", "mise", "shims", "codex"),
		filepath.Join(home, ".local", "share", "mise", "installs", "codex", "latest", "bin", "codex"),
	}
	maxAppIndex := -1
	for _, app := range desktopApps {
		idx := slices.Index(candidates, app)
		if idx < 0 {
			t.Fatalf("macOS 候选列表缺少桌面 App 路径 %q", app)
		}
		if idx > maxAppIndex {
			maxAppIndex = idx
		}
	}
	for _, fallback := range installerFallbacks {
		idx := slices.Index(candidates, fallback)
		if idx < 0 {
			t.Fatalf("macOS 候选列表缺少兜底安装路径 %q", fallback)
		}
		if idx <= maxAppIndex {
			t.Fatalf("兜底安装路径 %q (index=%d) 不得排在桌面 App (maxIndex=%d) 之前：%v", fallback, idx, maxAppIndex, candidates)
		}
	}

	tests := []struct {
		name       string
		configured string
		available  map[string]string
		want       string
	}{
		{
			name:       "explicit configured path beats PATH and desktop apps",
			configured: explicitCodex,
			available: map[string]string{
				explicitCodex:        explicitCodex,
				"codex":              pathCodex,
				systemChatGPT:        systemChatGPT,
				userChatGPT:          userChatGPT,
				homebrewAppleSilicon: homebrewAppleSilicon,
			},
			want: explicitCodex,
		},
		{
			name:       "PATH beats desktop apps and homebrew when both exist",
			configured: "codex",
			available: map[string]string{
				"codex":              pathCodex,
				systemChatGPT:        systemChatGPT,
				userChatGPT:          userChatGPT,
				homebrewAppleSilicon: homebrewAppleSilicon,
				homebrewIntel:        homebrewIntel,
			},
			want: pathCodex,
		},
		{
			name:       "system Applications beats user Applications and homebrew",
			configured: "codex",
			available: map[string]string{
				systemChatGPT:        systemChatGPT,
				userChatGPT:          userChatGPT,
				homebrewAppleSilicon: homebrewAppleSilicon,
				homebrewIntel:        homebrewIntel,
			},
			want: systemChatGPT,
		},
		{
			name:       "user Applications new embedded path beats /usr/local/bin/codex and homebrew",
			configured: "codex",
			available: map[string]string{
				userChatGPT:          userChatGPT,
				homebrewAppleSilicon: homebrewAppleSilicon,
				homebrewIntel:        homebrewIntel,
				userLocal:            userLocal,
			},
			want: userChatGPT,
		},
		{
			name:       "user Applications legacy path beats /usr/local/bin/codex",
			configured: "/missing/codex",
			available: map[string]string{
				userCodexLegacy: userCodexLegacy,
				homebrewIntel:   homebrewIntel,
				userLocal:       userLocal,
			},
			want: userCodexLegacy,
		},
		{
			name:       "homebrew fallback used only when PATH and desktop apps miss",
			configured: "codex",
			available: map[string]string{
				homebrewIntel: homebrewIntel,
				userLocal:     userLocal,
			},
			want: homebrewIntel,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			f := newDiscoveryFixture(t)
			f.Home = home
			pathDir := t.TempDir()
			f.env["PATH"] = pathDir
			for key, path := range tc.available {
				if key == "codex" {
					path = filepath.Join(pathDir, "codex")
				}
				f.add(t, path, "codex-cli 0.155.0")
			}
			resolved, err := f.repairCodex(context.Background(), RuntimeRequest{Name: "codex", Pin: tc.configured})
			want := tc.want
			if want == pathCodex {
				want = filepath.Join(pathDir, "codex")
			}
			if err != nil || resolved.Path != want {
				t.Fatalf("got %+v, %v; want %q", resolved, err, want)
			}
		})
	}
}

func TestDarwinPlatformCodexCandidatesIncludeEmbeddedChatGPTCLI(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS candidate list only applies to Darwin hosts")
	}
	candidates := NewRuntimeDiscovery().candidates(RuntimeRequest{Name: "codex"})
	const expected = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"
	if !slices.Contains(candidates, expected) {
		t.Fatalf("Darwin platformCodexCandidates 缺少 %q：%v", expected, candidates)
	}
}

func TestLinuxCodexCandidatesCoverCommonUserInstallers(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("Linux candidate list only applies to Linux hosts")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	candidates := NewRuntimeDiscovery().candidates(RuntimeRequest{Name: "codex"})
	for _, expected := range []string{
		filepath.Join(home, ".local", "bin", "codex"),
		filepath.Join(home, ".npm-global", "bin", "codex"),
		filepath.Join(home, ".local", "share", "mise", "shims", "codex"),
		filepath.Join(home, ".local", "share", "mise", "installs", "codex", "latest", "bin", "codex"),
	} {
		if !slices.Contains(candidates, expected) {
			t.Fatalf("Linux Codex fallback 缺少 %q：%v", expected, candidates)
		}
	}
}

func TestRepairCodexBinPreservesUserConfigAndSecrets(t *testing.T) {
	dir := t.TempDir()
	configPath := filepath.Join(dir, "config.json")
	original := map[string]any{
		"listen": "100.64.0.1:8787",
		"auth":   map[string]any{"token": "must-not-change"},
		"codex": map[string]any{
			"bin":           "/opt/homebrew/bin/codex",
			"default_args":  []string{"--no-alt-screen", "--keep"},
			"future_option": map[string]any{"enabled": true},
		},
		"projects":    []map[string]any{{"id": "demo", "path": "/tmp/demo"}},
		"future_root": map[string]any{"keep": []any{"value", 42.0}},
	}
	raw, err := json.MarshalIndent(original, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	var expected map[string]any
	if err := json.Unmarshal(raw, &expected); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(configPath, append(raw, '\n'), 0o600); err != nil {
		t.Fatal(err)
	}

	const recovered = "/Applications/ChatGPT.app/Contents/Resources/codex"
	path, repaired, err := repairCodexBin(configPath, func(configured string) (string, error) {
		if configured != "/opt/homebrew/bin/codex" {
			t.Fatalf("收到意外旧路径：%s", configured)
		}
		return recovered, nil
	}, writePrivateFileAtomically)
	if err != nil {
		t.Fatal(err)
	}
	if !repaired || path != recovered {
		t.Fatalf("应修复 Codex 路径：path=%q repaired=%v", path, repaired)
	}

	updatedRaw, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	var updated map[string]any
	if err := json.Unmarshal(updatedRaw, &updated); err != nil {
		t.Fatal(err)
	}
	updatedCodex := updated["codex"].(map[string]any)
	if updatedCodex["bin"] != recovered {
		t.Fatalf("Codex 路径未持久化：%+v", updatedCodex)
	}
	expectedCodex := expected["codex"].(map[string]any)
	delete(updatedCodex, "bin")
	delete(expectedCodex, "bin")
	if !reflect.DeepEqual(updated, expected) {
		t.Fatalf("修复不能改写其他配置：\nwant=%+v\n got=%+v", expected, updated)
	}
	info, err := os.Lstat(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if !info.Mode().IsRegular() || (runtime.GOOS != "windows" && info.Mode().Perm() != 0o600) {
		t.Fatalf("修复后的配置必须保持 0600 regular file：%v", info.Mode())
	}
}

func TestRepairCodexBinDoesNotRewriteValidAbsolutePath(t *testing.T) {
	dir := t.TempDir()
	configPath := filepath.Join(dir, "config.json")
	original := []byte("{\n  \"codex\": {\"bin\": \"/valid/codex\"},\n  \"future\": true\n}\n")
	if err := os.WriteFile(configPath, original, 0o600); err != nil {
		t.Fatal(err)
	}
	writeCalled := false
	path, repaired, err := repairCodexBin(configPath, func(configured string) (string, error) {
		return configured, nil
	}, func(string, []byte) error {
		writeCalled = true
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if repaired || writeCalled || path != "/valid/codex" {
		t.Fatalf("有效绝对路径不应重写：path=%q repaired=%v write=%v", path, repaired, writeCalled)
	}
}

func TestRepairCodexBinRejectsLegacySharingBeforeResolvingOrWriting(t *testing.T) {
	cfgPath := filepath.Join(t.TempDir(), "config.json")
	original := []byte(`{"app_server":{"transport":"ws","shared_fallback":{"transport":"ws"}},"codex":{"bin":"codex"}}`)
	if err := os.WriteFile(cfgPath, original, 0o600); err != nil {
		t.Fatal(err)
	}
	resolverCalled := false
	writerCalled := false
	_, _, err := repairCodexBin(cfgPath, func(string) (string, error) {
		resolverCalled = true
		return "/tmp/codex", nil
	}, func(string, []byte) error {
		writerCalled = true
		return nil
	})
	if !errors.Is(err, config.ErrLegacyAppServerConfiguration) {
		t.Fatalf("legacy sharing must fail closed: %v", err)
	}
	if resolverCalled || writerCalled {
		t.Fatalf("legacy sharing must be rejected before repair: resolve=%t write=%t", resolverCalled, writerCalled)
	}
	stored, readErr := os.ReadFile(cfgPath)
	if readErr != nil || !reflect.DeepEqual(stored, original) {
		t.Fatalf("legacy config must stay byte-identical: err=%v raw=%s", readErr, stored)
	}
}
