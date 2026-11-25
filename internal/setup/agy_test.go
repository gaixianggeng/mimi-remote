package setup

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/agybridge"
)

func TestB11Round3ConfigureAgyDistinguishesSignedInSignedOutAndUnknown(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell script fixture requires POSIX")
	}
	dir := t.TempDir()
	adapterPath := filepath.Join(dir, "mimi-agy-adapter")
	adapterScript := `#!/bin/sh
if [ "$1" = "--version" ]; then echo "0.1.0"; exit 0; fi
if [ "$1" = "--capabilities" ]; then
  echo '{"name":"mimi-agy-adapter","version":"0.1.0","methods":["initialize","thread/list","turn/start"],"fullAccess":true,"agy":{"minimumVersion":"1.5.0"}}'
  exit 0
fi
exit 0
`
	if err := os.WriteFile(adapterPath, []byte(adapterScript), 0o755); err != nil {
		t.Fatal(err)
	}

	agyPath := filepath.Join(dir, "agy")
	agyScript := `#!/bin/sh
if [ "$1" = "--version" ]; then echo "1.5.14"; exit 0; fi
while [ $# -gt 0 ]; do
  case "$1" in
    --gemini_dir|--app_data_dir) shift 2 ;;
    models)
      shift
      if [ $# -gt 0 ]; then echo "Usage: agy models [flags]" >&2; exit 2; fi
      case "$TEST_AUTH_STATE" in
        signed_in) echo "gemini-4-neon-high"; exit 0 ;;
        signed_out) echo "Error: Please sign in to view available models." >&2; exit 1 ;;
        unknown) echo "Usage: agy models [flags]" >&2; exit 2 ;;
      esac
      exit 2
      ;;
    *) echo "flags provided but not defined: $1" >&2; exit 2 ;;
  esac
done
exit 2
`
	if err := os.WriteFile(agyPath, []byte(agyScript), 0o755); err != nil {
		t.Fatal(err)
	}

	writeCfg := func(t *testing.T, authState string) string {
		t.Helper()
		cfgPath := filepath.Join(t.TempDir(), "agentd.json")
		doc := map[string]any{
			"listen": "127.0.0.1:8787",
			"agy": map[string]any{
				"enabled":     false,
				"adapter_bin": adapterPath,
				"env": map[string]string{
					agybridge.AgyBinaryEnvKey:     agyPath,
					agybridge.AgyGeminiDirEnvKey:  ".gemini-iso",
					agybridge.AgyAppDataDirEnvKey: "iso-cli",
					"TEST_AUTH_STATE":             authState,
				},
			},
		}
		raw, err := json.MarshalIndent(doc, "", "  ")
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(cfgPath, raw, 0o600); err != nil {
			t.Fatal(err)
		}
		return cfgPath
	}

	configure := func(authState string) (AgyConfigurationResult, error) {
		return configureAgyWithCandidates(context.Background(), writeCfg(t, authState), AgyActivationEnabled, nil,
			func(configured string) []string { return []string{configured} })
	}

	// 1) Unknown / usage error must report agy_auth_unknown with LoggedIn == nil (NEVER agy_signed_out).
	resUnknown, err := configure("unknown")
	if err != nil {
		t.Fatalf("ConfigureAgy unknown: %v", err)
	}
	if resUnknown.Available || resUnknown.Reason != "agy_auth_unknown" || resUnknown.LoggedIn != nil {
		t.Fatalf("expected available=false reason=agy_auth_unknown logged_in=nil, got %+v", resUnknown)
	}

	// 2) Signed out must report agy_signed_out with LoggedIn == false.
	resSignedOut, err := configure("signed_out")
	if err != nil {
		t.Fatalf("ConfigureAgy signed_out: %v", err)
	}
	if resSignedOut.Available || resSignedOut.Reason != "agy_signed_out" || resSignedOut.LoggedIn == nil || *resSignedOut.LoggedIn {
		t.Fatalf("expected available=false reason=agy_signed_out logged_in=false, got %+v", resSignedOut)
	}

	// 3) Signed in with isolated account flags succeeds and enables channel.
	resSignedIn, err := configure("signed_in")
	if err != nil {
		t.Fatalf("ConfigureAgy signed_in: %v", err)
	}
	if !resSignedIn.Available || !resSignedIn.Enabled || resSignedIn.Reason != "ready" || resSignedIn.LoggedIn == nil || !*resSignedIn.LoggedIn {
		t.Fatalf("expected ready & enabled, got %+v", resSignedIn)
	}
}
