package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/diagnosticlog"
)

func TestDiagnosticClearRejectsReplacedActiveFile(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 不允许重命名此处保持打开的日志文件")
	}
	path := filepath.Join(t.TempDir(), "agentd.log")
	writer, err := newRotatingLogWriter(path, defaultManagedLogMaxBytes)
	if err != nil {
		t.Fatal(err)
	}
	defer writer.Close()
	if err := os.Rename(path, path+".moved"); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("keep replacement"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := writer.clear(); err == nil {
		t.Fatal("日志路径被替换后必须停止清除")
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != "keep replacement" {
		t.Fatal("不能截断替换后的文件")
	}
}

func diagnosticTestLine(t *testing.T, at time.Time) string {
	t.Helper()
	line, ok := diagnosticlog.Format(diagnosticlog.Event{At: at, Stage: "http", Outcome: "failed", StatusCode: 503})
	if !ok {
		t.Fatal("invalid test event")
	}
	return line + "\n"
}

func TestDiagnosticUpgradePreservesRecentLegacyButNeverExportsIt(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agentd.log")
	now := time.Now()
	recent := now.Add(-time.Hour).Format("2006/01/02 15:04:05") + " old user-sensitive details\n"
	expired := now.Add(-8*24*time.Hour).Format("2006/01/02 15:04:05") + " old expired details\n"
	if err := os.WriteFile(path, []byte(recent+expired), 0o600); err != nil {
		t.Fatal(err)
	}
	logs, closeLogs, err := configureServeFileLogging(path)
	if err != nil {
		t.Fatal(err)
	}
	defer closeLogs()
	lines, err := logs.Export()
	if err != nil || len(lines) != 0 {
		t.Fatal("旧自由文本不能进入安全报告")
	}
	data, _ := os.ReadFile(path)
	if string(data) != recent {
		t.Fatal("升级只能裁剪过期旧记录")
	}
}

func TestManagedDiagnosticsRetentionAndSafeExport(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agentd.log")
	now := time.Now().UTC()
	fresh := diagnosticTestLine(t, now.Add(-time.Hour))
	expired := diagnosticTestLine(t, now.Add(-8*24*time.Hour))
	withExtra := strings.TrimSuffix(strings.TrimSpace(fresh), "}") + `,"secret":"private-body"}` + "\n"
	if err := os.WriteFile(path, []byte(expired+withExtra+"raw path /private/project secret\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path+".previous", []byte(expired), 0o600); err != nil {
		t.Fatal(err)
	}
	logs, closeLogs, err := configureServeFileLogging(path)
	if err != nil {
		t.Fatal(err)
	}
	defer closeLogs()
	lines, err := logs.Export()
	if err != nil || len(lines) != 1 || lines[0]+"\n" != fresh {
		t.Fatalf("export=%v err=%v", lines, err)
	}
	data, _ := os.ReadFile(path)
	if string(data) != fresh {
		t.Fatal("启动时必须裁剪过期与自由文本记录")
	}
	status, err := logs.Status()
	if err != nil || status.Enabled || status.TotalBytes > status.MaxTotalBytes || status.RetentionDays != 7 {
		t.Fatalf("status=%+v err=%v", status, err)
	}
	if _, err := os.Stat(path + ".previous"); !os.IsNotExist(err) {
		t.Fatal("过期 previous 未清理")
	}
}

func TestManagedDiagnosticsClearRestartAndConcurrentWrites(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agentd.log")
	logs, closeLogs, err := configureServeFileLogging(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := logs.SetEnabled(true); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 50; j++ {
				logs.recorder.Record("http", "failed", diagnosticlog.Fields{StatusCode: 500})
			}
		}()
	}
	if _, err := logs.Clear(); err != nil {
		t.Fatal(err)
	}
	wg.Wait()
	status, err := logs.Clear()
	if err != nil || status.TotalBytes != 0 {
		t.Fatalf("清空失败 %+v %v", status, err)
	}
	logs.recorder.Record("http", "failed", diagnosticlog.Fields{StatusCode: 500})
	lines, err := logs.Export()
	if err != nil || len(lines) != 1 {
		t.Fatalf("清理后无法继续记录: %v %v", lines, err)
	}
	closeLogs()
	logs, closeAgain, err := configureServeFileLogging(path)
	if err != nil {
		t.Fatal(err)
	}
	defer closeAgain()
	status, err = logs.Status()
	if err != nil || status.Enabled || status.TotalBytes == 0 {
		t.Fatal("重启应关闭详细模式并保留必要故障")
	}
}

func TestDiagnosticRetentionUsesRecordAgeNotFileModificationTime(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agentd.log")
	w, err := newRotatingLogWriter(path, 4096)
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	now := time.Now().UTC()
	_, _ = w.Write([]byte(diagnosticTestLine(t, now.Add(-8*24*time.Hour)) + diagnosticTestLine(t, now)))
	if err := w.prune(now); err != nil {
		t.Fatal(err)
	}
	lines, _ := w.export(now)
	if len(lines) != 1 {
		t.Fatal("近期写入不能延长旧记录的生命周期")
	}
	if err := w.prune(now.Add(8 * 24 * time.Hour)); err != nil {
		t.Fatal(err)
	}
	info, _ := os.Stat(path)
	if info.Size() != 0 {
		t.Fatal("持续运行期间也必须裁剪过期记录")
	}
}

func TestDiagnosticReadIsBoundedAndRejectsPreviousSymlink(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agentd.log")
	w, err := newRotatingLogWriter(path, 1024)
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	for i := 0; i < 50; i++ {
		_, _ = w.Write([]byte(diagnosticTestLine(t, time.Now())))
	}
	lines, err := w.export(time.Now())
	if err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(lines)
	if len(data) > 4096 {
		t.Fatal("export escaped bounded capacity")
	}
	_ = os.Remove(path + ".previous")
	target := filepath.Join(t.TempDir(), "untouched")
	_ = os.WriteFile(target, []byte("preserve"), 0o600)
	if err := os.Symlink(target, path+".previous"); err != nil {
		t.Skip("symlinks unavailable")
	}
	if err := w.prune(time.Now()); err == nil {
		t.Fatal("必须拒绝 previous 符号链接")
	}
	data, _ = os.ReadFile(target)
	if string(data) != "preserve" {
		t.Fatal("不得修改符号链接目标")
	}
}
