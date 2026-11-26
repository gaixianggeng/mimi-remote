//go:build !windows

package tailscaleinfo

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// The background sleep holds a FIFO open even after its wrapper exits. EOF
// gives direct evidence that the status probe cleaned up its descendants.
func TestTunnelAvailableCleansSuccessfulStatusWrapper(t *testing.T) {
	dir := t.TempDir()
	fifo := filepath.Join(dir, "tailscale.fifo")
	if err := syscall.Mkfifo(fifo, 0600); err != nil {
		t.Fatal(err)
	}
	reader, err := os.OpenFile(fifo, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	shim := filepath.Join(dir, "tailscale")
	script := `#!/bin/sh
[ "$1" = status ] && [ "$2" = --json ] || exit 1
exec 3>"$0.fifo"
sleep 5 </dev/null >/dev/null 2>&1 &
echo '{"BackendState":"Running"}'
printf 'x' >&3
`
	if err := os.WriteFile(shim, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+"/bin")
	if !TunnelAvailable(context.Background()) {
		t.Fatal("running status wrapper did not report an available tunnel")
	}
	var marker [1]byte
	if _, err := reader.Read(marker[:]); err != nil || marker[0] != 'x' {
		t.Fatalf("status wrapper did not run: marker=%q, err=%v", marker, err)
	}
	fd := int(reader.Fd())
	if err := syscall.SetNonblock(fd, true); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(time.Second)
	for {
		n, err := syscall.Read(fd, marker[:])
		if n == 0 && err == nil {
			return // EOF: no writer survived the successful status call.
		}
		if !errors.Is(err, syscall.EAGAIN) || time.Now().After(deadline) {
			t.Fatalf("status child still holds FIFO: read=%d, err=%v", n, err)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// Exercise the failure exits on the same Bash that runs the actual self-test.
// Each copy changes only one stub response so both positive assertions matter.
func TestHistorySyncSelfTestFailsOnEitherStub(t *testing.T) {
	source, err := os.ReadFile("../../scripts/history-sync-regression.sh")
	if err != nil {
		t.Fatal(err)
	}
	for _, response := range []string{"echo 100.64.0.1", "STUB_IP:-100.64.0.2"} {
		t.Run(response, func(t *testing.T) {
			changed := strings.Replace(string(source), response, strings.Replace(response, "100.64.0.", "100.65.0.", 1), 1)
			if changed == string(source) {
				t.Fatal("expected stub not found")
			}
			path := filepath.Join(t.TempDir(), "history-sync-regression.sh")
			if err := os.WriteFile(path, []byte(changed), 0700); err != nil {
				t.Fatal(err)
			}
			cmd := exec.Command("bash", path, "--self-test")
			out, err := cmd.CombinedOutput()
			var exitErr *exec.ExitError
			if !errors.As(err, &exitErr) || exitErr.ExitCode() != 1 || !strings.Contains(string(out), "assertion failed") || strings.Contains(string(out), "discovery passed") {
				t.Fatalf("bad stub response: %v, %s", err, out)
			}
		})
	}
}
