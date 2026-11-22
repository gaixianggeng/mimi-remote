package agybridge

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestBuildEnvStripsAntigravityDesktopVariables(t *testing.T) {
	t.Setenv("ANTIGRAVITY_APP_DATA_DIR", "antigravity")
	t.Setenv("__CFBundleIdentifier", "com.google.antigravity")

	env := BuildEnv(map[string]string{
		AgyBinaryEnvKey:          "/usr/local/bin/agy",
		"ANTIGRAVITY_CSRF_TOKEN": "should-not-leak",
	})
	foundBin := false
	for _, entry := range env {
		if strings.HasPrefix(entry, "ANTIGRAVITY_") || strings.HasPrefix(entry, "__CFBundleIdentifier=") {
			t.Fatalf("unexpected desktop leak in env: %s", entry)
		}
		if entry == AgyBinaryEnvKey+"=/usr/local/bin/agy" {
			foundBin = true
		}
	}
	if !foundBin {
		t.Fatalf("expected %s in built env", AgyBinaryEnvKey)
	}
}

func TestParseAdapterCapabilitiesAndVersionGate(t *testing.T) {
	caps, err := ParseAdapterCapabilities([]byte(`{
		"name":"mimi-agy-adapter",
		"version":"0.1.0",
		"methods":["initialize","thread/list","turn/start","slashCommand/list"],
		"fullAccess":true,
		"agy":{"minimumVersion":"1.5.0"}
	}`))
	if err != nil {
		t.Fatal(err)
	}
	if !caps.FullAccess || !caps.Supports("slashCommand/list") {
		t.Fatalf("unexpected capabilities: %+v", caps)
	}
	if !caps.AgySupported("1.5.10") || caps.AgySupported("1.4.9") {
		t.Fatalf("version comparison mismatch")
	}
}

func TestB11Round3AgyModelsArgsUseGlobalUnderscoreFlagsBeforeModels(t *testing.T) {
	defaultArgs := AgyModelsArgs([]string{
		AgyGeminiDirEnvKey + "=.gemini",
		AgyAppDataDirEnvKey + "=antigravity-cli",
	})
	if !reflect.DeepEqual(defaultArgs, []string{"models"}) {
		t.Fatalf("expected default args [models], got %v", defaultArgs)
	}

	isolatedArgs := AgyModelsArgs([]string{
		AgyGeminiDirEnvKey + "=.gemini-isolated",
		AgyAppDataDirEnvKey + "=antigravity-custom",
	})
	want := []string{"--gemini_dir", ".gemini-isolated", "--app_data_dir", "antigravity-custom", "models"}
	if !reflect.DeepEqual(isolatedArgs, want) {
		t.Fatalf("expected global underscore flags before models %v, got %v", want, isolatedArgs)
	}
}

func TestB11Round3CheckAgyAuthStatusRespectsStrictCLIFlagSyntaxAndThreeStates(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell script fixture requires POSIX")
	}
	dir := t.TempDir()
	agyBin := filepath.Join(dir, "agy")

	// Strict fixture mirroring real `agy 1.5.14`: accepts only global --gemini_dir / --app_data_dir BEFORE models.
	script := `#!/bin/sh
gemini=""
appdata=""
while [ $# -gt 0 ]; do
  case "$1" in
    --gemini_dir) gemini="$2"; shift 2 ;;
    --app_data_dir) appdata="$2"; shift 2 ;;
    models)
      shift
      if [ $# -gt 0 ]; then
        echo "Usage: agy models [flags]" >&2
        exit 2
      fi
      case "$MOCK_AUTH_MODE" in
        signed_in)
          echo "gemini-4-neon-high  Gemini 4 Neon (High) [$gemini:$appdata]"
          exit 0
          ;;
        signed_out)
          echo "Error: Please sign in to view available models. Launch the CLI without arguments to sign in." >&2
          exit 1
          ;;
        slow)
          /bin/sleep 2
          exit 0
          ;;
        *)
          echo "unexpected upstream failure" >&2
          exit 1
          ;;
      esac
      ;;
    *)
      echo "flags provided but not defined: $1" >&2
      exit 2
      ;;
  esac
done
exit 2
`
	if err := os.WriteFile(agyBin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}

	baseEnv := []string{
		"PATH=" + os.Getenv("PATH"),
		AgyGeminiDirEnvKey + "=.gemini-iso",
		AgyAppDataDirEnvKey + "=iso-cli",
	}

	state, msg := CheckAgyAuthStatus(context.Background(), agyBin, append(append([]string{}, baseEnv...), "MOCK_AUTH_MODE=signed_in"))
	if state != AgyAuthSignedIn || msg != "" {
		t.Fatalf("expected signed_in, got state=%s msg=%q", state, msg)
	}

	state, msg = CheckAgyAuthStatus(context.Background(), agyBin, append(append([]string{}, baseEnv...), "MOCK_AUTH_MODE=signed_out"))
	if state != AgyAuthSignedOut || !strings.Contains(msg, "尚未登录") {
		t.Fatalf("expected signed_out, got state=%s msg=%q", state, msg)
	}

	state, msg = CheckAgyAuthStatus(context.Background(), agyBin, append(append([]string{}, baseEnv...), "MOCK_AUTH_MODE=unknown"))
	if state != AgyAuthUnknown || !strings.Contains(msg, "unexpected upstream failure") {
		t.Fatalf("expected unknown on generic error, got state=%s msg=%q", state, msg)
	}

	shortCtx, cancel := context.WithTimeout(context.Background(), 120*time.Millisecond)
	defer cancel()
	state, msg = CheckAgyAuthStatus(shortCtx, agyBin, append(append([]string{}, baseEnv...), "MOCK_AUTH_MODE=slow"))
	if state != AgyAuthUnknown || !strings.Contains(msg, "超时") {
		t.Fatalf("expected unknown on timeout, got state=%s msg=%q", state, msg)
	}
}
