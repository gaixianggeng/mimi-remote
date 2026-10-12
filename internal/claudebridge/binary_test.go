package claudebridge

import (
	"os"
	"path/filepath"
	"testing"
)

func TestResolveBinaryMacAppPrefersBundledBridge(t *testing.T) {
	executable, bundled, external := binaryResolutionFixtures(t, true)

	got, ok := resolveBinary(external, executable, false)
	if !ok || got != bundled {
		t.Fatalf("Mac App 应优先选择随包 bridge：got=(%q,%t), want=(%q,true)", got, ok, bundled)
	}
}

func TestResolveBinaryCLIUsesConfiguredOldBridgeWithoutBundledAdapter(t *testing.T) {
	executable, bundled, external := binaryResolutionFixtures(t, true)

	// Homebrew、Linux 发布包没有随包适配器：配置里的旧 bridge 照常可用。
	cliExecutable := filepath.Join(filepath.Dir(filepath.Dir(filepath.Dir(filepath.Dir(executable)))), "agentd")
	got, ok := resolveBinary(external, cliExecutable, false)
	if !ok || got != external {
		t.Fatalf("没有随包适配器时应继续用配置的旧 bridge：got=(%q,%t), want=(%q,true)", got, ok, external)
	}

	// 保留随包文件，确保该测试验证的是路径形态，而非 bridge 缺失回退。
	if _, err := os.Stat(bundled); err != nil {
		t.Fatalf("测试 fixture 缺少随包 bridge：%v", err)
	}
}

func TestResolveBinaryMacAppFallsBackWhenBundledBridgeMissing(t *testing.T) {
	executable, _, external := binaryResolutionFixtures(t, false)

	got, ok := resolveBinary(external, executable, false)
	if !ok || got != external {
		t.Fatalf("Mac App 随包 bridge 缺失时应回退显式 bridge：got=(%q,%t), want=(%q,true)", got, ok, external)
	}
}

func TestResolveBinaryFailsWhenNoBridgeIsAvailable(t *testing.T) {
	executable, _, _ := binaryResolutionFixtures(t, false)
	missing := filepath.Join(t.TempDir(), "missing-bridge")

	got, ok := resolveBinary(missing, executable, false)
	if ok || got != missing {
		t.Fatalf("无可用 bridge 时应返回失败和原始命令：got=(%q,%t), want=(%q,false)", got, ok, missing)
	}
}

func TestResolveBinaryMacAppDefaultsToBundledAdapterAndHonorsLegacySwitch(t *testing.T) {
	executable, bundled, external := binaryResolutionFixtures(t, true)
	adapter := filepath.Join(filepath.Dir(executable), AdapterBinaryName)
	writeExecutableFixture(t, adapter)

	if got, ok := resolveBinary(external, executable, false); !ok || got != adapter {
		t.Fatalf("Mac App 默认应使用随包适配器：got=(%q,%t), want=(%q,true)", got, ok, adapter)
	}
	if got, ok := resolveBinary(external, executable, true); !ok || got != bundled {
		t.Fatalf("回退开关打开时应使用随包旧 bridge：got=(%q,%t), want=(%q,true)", got, ok, bundled)
	}
	// 包里没有旧 bridge 时，回退开关无法兑现，仍用随包适配器，不去找外置版本。
	if err := os.Remove(bundled); err != nil {
		t.Fatal(err)
	}
	if got, ok := resolveBinary(external, executable, true); !ok || got != adapter {
		t.Fatalf("包里没有旧 bridge 时应继续用随包适配器：got=(%q,%t), want=(%q,true)", got, ok, adapter)
	}
}

func TestResolveBinaryCLIPrefersSiblingAdapterOverOldBridgeConfig(t *testing.T) {
	root := t.TempDir()
	executable := filepath.Join(root, "bin", "agentd")
	adapter := filepath.Join(root, "bin", AdapterBinaryName)
	cargoBridge := filepath.Join(root, ".cargo", "bin", BinaryName)
	for _, path := range []string{executable, adapter, cargoBridge} {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		writeExecutableFixture(t, path)
	}

	// 旧版本写下的默认配置（默认名或 cargo 安装路径）不代表要固定旧实现。
	for _, configured := range []string{"", BinaryName, cargoBridge} {
		if got, ok := resolveBinary(configured, executable, false); !ok || got != adapter {
			t.Fatalf("配置 %q 时默认应使用同目录适配器：got=(%q,%t), want=(%q,true)", configured, got, ok, adapter)
		}
	}
	if got, ok := resolveBinary(cargoBridge, executable, true); !ok || got != cargoBridge {
		t.Fatalf("回退开关打开时应使用配置的旧 bridge：got=(%q,%t), want=(%q,true)", got, ok, cargoBridge)
	}

	// 明确指向别的程序（例如开发时自己构建的适配器）时照用。
	devAdapter := filepath.Join(root, "dev", "dist", "mimi-claude-adapter-dev"+filepath.Ext(AdapterBinaryName))
	if err := os.MkdirAll(filepath.Dir(devAdapter), 0o755); err != nil {
		t.Fatal(err)
	}
	writeExecutableFixture(t, devAdapter)
	if got, ok := resolveBinary(devAdapter, executable, false); !ok || got != devAdapter {
		t.Fatalf("显式配置的其他程序应优先：got=(%q,%t), want=(%q,true)", got, ok, devAdapter)
	}
}

func TestExplicitBridgeCommandIgnoresOldBridgeDefaults(t *testing.T) {
	for command, want := range map[string]bool{
		"":                       false,
		"  ":                     false,
		"alleycat-claude-bridge": false,
		"/opt/homebrew/bin/alleycat-claude-bridge":                 false,
		`C:\Program Files\Mimi Remote\alleycat-claude-bridge.exe`:  false,
		"/Users/a/dev/bridges/claude-sdk/dist/mimi-claude-adapter": true,
		"my-wrapper": true,
	} {
		if got := explicitBridgeCommand(command); got != want {
			t.Fatalf("explicitBridgeCommand(%q)=%t, want %t", command, got, want)
		}
	}
}

func binaryResolutionFixtures(t *testing.T, bundledAvailable bool) (executable, bundled, external string) {
	t.Helper()
	root := t.TempDir()
	resources := filepath.Join(root, "Mimi Remote.app", "Contents", "Resources")
	executable = filepath.Join(resources, "agentd")
	bundled = filepath.Join(resources, BinaryName)
	external = filepath.Join(root, "old", BinaryName)
	if err := os.MkdirAll(filepath.Dir(executable), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(external), 0o755); err != nil {
		t.Fatal(err)
	}
	writeExecutableFixture(t, external)
	if bundledAvailable {
		writeExecutableFixture(t, bundled)
	}
	return executable, bundled, external
}

func writeExecutableFixture(t *testing.T, path string) {
	t.Helper()
	if err := os.WriteFile(path, []byte("bridge fixture\n"), 0o755); err != nil {
		t.Fatal(err)
	}
}
