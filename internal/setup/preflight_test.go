package setup

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/config/configtest"
)

func preflightSandbox(t *testing.T) string {
	t.Helper()
	home := t.TempDir()
	for _, e := range os.Environ() {
		k, _, _ := strings.Cut(e, "=")
		if strings.HasPrefix(strings.ToUpper(k), "AGENTD_") {
			t.Setenv(k, "")
		}
	}
	for _, key := range []string{"HOME", "USERPROFILE", "APPDATA", "LOCALAPPDATA", "XDG_CONFIG_HOME", "PATH"} {
		t.Setenv(key, home)
	}
	return home
}

func TestPreflightOverlappingPollsPreservePrivateFiles(t *testing.T) {
	home := preflightSandbox(t)
	root := filepath.Join(home, "selected")
	cfg := config.DefaultPath()
	legacy := config.LegacyDefaultPath()
	token := filepath.Join(home, "companion")
	protected := filepath.Join(root, "protected")
	for _, dir := range []string{filepath.Dir(cfg), filepath.Dir(legacy), protected} {
		if err := os.MkdirAll(dir, 0700); err != nil {
			t.Fatal(err)
		}
	}
	contents, err := json.Marshal(map[string]any{"auth": map[string]string{"token": "synthetic-test-bearer"}, "scan_roots": []string{root}, "browse_roots": []string{root}, "deepseek": map[string]string{"token_file": token}, "unknown": "preserve"})
	if err != nil {
		t.Fatal(err)
	}
	for path, data := range map[string][]byte{cfg: contents, legacy: []byte("preserved legacy bytes"), token: []byte("synthetic companion"), filepath.Join(protected, "marker"): []byte("unchanged")} {
		configtest.CreatePrivateFile(t, path, data)
	}
	digest := func() map[string][32]byte {
		files := map[string][32]byte{}
		err := filepath.WalkDir(home, func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if d.IsDir() {
				files[path] = [32]byte{}
				return nil
			}
			b, err := os.ReadFile(path)
			if err == nil {
				files[path] = sha256.Sum256(b)
			}
			return err
		})
		if err != nil {
			t.Fatal(err)
		}
		return files
	}
	before := digest()
	probes := PreflightProbes{Platform: "linux", Host: func(context.Context, config.Config) (PreflightHost, error) {
		return PreflightHost{}, PreflightHostError("service_not_running")
	},
		Member: func(context.Context, string, config.Config, string, PreflightHost) PreflightObservation {
			return PreflightObservation{Code: "probe_timeout"}
		}}
	var wg sync.WaitGroup
	for i := 0; i < 6; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r := InspectPreflight(t.Context(), PreflightOptions{ConfigPath: cfg}, probes, nil)
			if !r.Configured || !r.WorkspaceConfirmed || !r.OK || r.ScanRoot != root || r.BrowseRoot != root {
				t.Errorf("incorrect workspace/config observations: %v", r.Checks[:2])
			}
		}()
	}
	wg.Wait()
	if !reflect.DeepEqual(before, digest()) {
		t.Fatal("poll changed sandbox contents")
	}
	// An explicit fresh preview with legacy data present must never migrate it.
	if err := os.Remove(cfg); err != nil {
		t.Fatal(err)
	}
	before = digest()
	r := InspectPreflight(t.Context(), PreflightOptions{ScanRoot: root}, probes, nil)
	if r.Configured || !reflect.DeepEqual(before, digest()) {
		t.Fatal("poll migrated legacy configuration")
	}
}

func TestPreflightHungPolicyRespectsParentDeadline(t *testing.T) {
	root := preflightSandbox(t)
	release := make(chan struct{})
	defer close(release)
	started := make(chan struct{})
	probes := PreflightProbes{Platform: "windows", Member: func(_ context.Context, id string, _ config.Config, _ string, _ PreflightHost) PreflightObservation {
		if id == "network_lan" {
			close(started)
			<-release
		}
		return PreflightObservation{Code: "probe_timeout"}
	}}
	ctx, cancel := context.WithTimeout(t.Context(), 150*time.Millisecond)
	defer cancel()
	start := time.Now()
	r := InspectPreflight(ctx, PreflightOptions{ConfigPath: filepath.Join(root, "missing"), ScanRoot: root}, probes, nil)
	select {
	case <-started:
	default:
		t.Fatal("policy was never inspected")
	}
	if time.Since(start) > 2*time.Second {
		t.Fatal("waited for hung policy beyond request deadline")
	}
	for _, row := range r.Checks {
		if row.State == "checking" || row.ID == "network_lan" && (row.Code != "probe_timeout" || row.Available == nil || *row.Available != nil) {
			t.Fatalf("unfinished deadline observation: %+v", row)
		}
	}
}

func TestPreflightInspectRuntimeKeepsAttemptOrder(t *testing.T) {
	f := newDiscoveryFixture(t)
	dir := t.TempDir()
	old := filepath.Join(dir, "codex")
	f.add(t, old, "codex-cli 0.140.0")
	f.add(t, discoveryTestBundle, "codex-cli 0.155.0")
	var seen []string
	got, err := f.resolve(t.Context(), codexRequestWithPATH(dir), func(path, version, outcome string) {
		if path == old || path == discoveryTestBundle {
			seen = append(seen, version+" "+outcome)
		}
	})
	if err != nil || got.Path != discoveryTestBundle || !reflect.DeepEqual(seen, []string{"0.140.0 unsupported", "0.155.0 compatible"}) {
		t.Fatalf("trace %q selection %q err %v", seen, got.Version, err)
	}
}
