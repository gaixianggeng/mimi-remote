//go:build darwin

package appserver

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestDarwinResidentLaunchCommandWrapsBinaryWithOpenFileLimit(t *testing.T) {
	bin, args := residentLaunchCommand("/opt/codex", []string{"app-server", "--listen", "unix://"})
	if bin != "/bin/sh" {
		t.Fatalf("resident launcher = %q, want /bin/sh", bin)
	}
	want := []string{"-c", darwinResidentLaunchScript, "/opt/codex", "app-server", "--listen", "unix://"}
	if strings.Join(args, "\x00") != strings.Join(want, "\x00") {
		t.Fatalf("resident launcher args = %q, want %q", args, want)
	}
}

func TestDarwinStartResidentCommandRaisesOpenFileLimitAndDetaches(t *testing.T) {
	hardLimit, err := exec.Command("/bin/sh", "-c", "ulimit -Hn").Output()
	if err != nil {
		t.Fatal(err)
	}
	if hard := strings.TrimSpace(string(hardLimit)); hard != "unlimited" {
		if value, parseErr := strconv.Atoi(hard); parseErr == nil && value < 8192 {
			t.Skipf("hard open-file limit %d is below 8192", value)
		}
	}
	root := t.TempDir()
	marker := filepath.Join(root, "resident-limit")
	err = startResidentCommand(
		"/bin/sh",
		[]string{"-c", `printf '%s %s %s' "$(ulimit -Sn)" "$$" "$(ps -o pgid= -p $$ | tr -d ' ')" > "$MIMI_RESIDENT_MARKER"; sleep 1`},
		map[string]string{"HOME": root, "MIMI_RESIDENT_MARKER": marker},
	)
	if err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(3 * time.Second)
	var contents []byte
	for time.Now().Before(deadline) {
		contents, err = os.ReadFile(marker)
		if err == nil && len(contents) > 0 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	fields := strings.Fields(string(contents))
	if len(fields) != 3 {
		t.Fatalf("resident marker = %q, want '<limit> <pid> <pgid>'", contents)
	}
	if fields[0] != "unlimited" {
		limit, parseErr := strconv.Atoi(fields[0])
		if parseErr != nil || limit < 8192 {
			t.Fatalf("resident open-file soft limit = %q, want >= 8192", fields[0])
		}
	}
	// setsid 后 resident 是自己进程组的组长，不再属于 agentd 的进程组；
	// launchd 回收 agentd job 时只会终止 agentd 所在的进程组。
	if fields[1] != fields[2] {
		t.Fatalf("resident pid %s must lead its own process group, got pgid %s", fields[1], fields[2])
	}
	if fields[2] == strconv.Itoa(syscall.Getpgrp()) {
		t.Fatalf("resident must not share agentd process group %s", fields[2])
	}
}
