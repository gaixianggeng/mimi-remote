package main

import (
	"errors"
	"os"
	"path/filepath"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/debuglog"
	"github.com/gaixianggeng/mimi-remote/internal/diagnosticlog"
	"github.com/gaixianggeng/mimi-remote/internal/httpapi"
)

// debugLogFileName 是与安全诊断日志同目录的本机调试日志。
const debugLogFileName = "agentd-debug.log"

type managedDiagnosticLogs struct {
	writer   *rotatingLogWriter
	recorder *diagnosticlog.Recorder
	// 调试日志跟随同一个详细记录窗口；只按大小轮转，不参与安全日志的保留与导出。
	debugWriter *rotatingLogWriter
	debug       *debuglog.Sink
}

func debugLogPath(diagnosticPath string) string {
	return filepath.Join(filepath.Dir(diagnosticPath), debugLogFileName)
}

// 配置或运行环境在 HTTP 启动前失败时也留固定故障码；不能把原始错误写进报告。
func recordDiagnosticStartupFailure(path string) {
	writer, err := newRotatingLogWriter(path, defaultManagedLogMaxBytes)
	if err != nil {
		return
	}
	defer writer.Close()
	if err := writer.prune(time.Now()); err != nil {
		return
	}
	recorder, err := diagnosticlog.New(writer)
	if err == nil {
		recorder.Record("service", "failed", diagnosticlog.Fields{})
		recorder.Close()
	}
}

func configureServeFileLogging(path string) (*managedDiagnosticLogs, func(), error) {
	if path == "" {
		return nil, nil, nil
	}
	writer, err := newRotatingLogWriter(path, defaultManagedLogMaxBytes)
	if err != nil {
		return nil, nil, err
	}
	if err := writer.prune(time.Now()); err != nil {
		_ = writer.Close()
		return nil, nil, err
	}
	recorder, err := diagnosticlog.New(writer)
	if err != nil {
		_ = writer.Close()
		return nil, nil, err
	}
	debugWriter, err := newRotatingLogWriter(debugLogPath(writer.path), defaultManagedLogMaxBytes)
	if err != nil {
		recorder.Close()
		_ = writer.Close()
		return nil, nil, err
	}
	removeRecorder := diagnosticlog.Install(recorder)
	debug := debuglog.New(debugWriter, func() bool { return recorder.ExpiresAt() != nil })
	removeDebug := debuglog.Install(debug)
	logs := &managedDiagnosticLogs{writer: writer, recorder: recorder, debugWriter: debugWriter, debug: debug}
	stop := make(chan struct{})
	done := make(chan struct{})
	go func() {
		defer close(done)
		ticker := time.NewTicker(time.Hour)
		defer ticker.Stop()
		for {
			select {
			case <-stop:
				return
			case now := <-ticker.C:
				_ = writer.prune(now)
			}
		}
	}()
	return logs, func() {
		removeDebug()
		removeRecorder()
		close(stop)
		<-done
		debug.Close()
		recorder.Close()
		_ = debugWriter.Close()
		_ = writer.Close()
	}, nil
}

func (l *managedDiagnosticLogs) Status() (httpapi.DiagnosticLogStatus, error) {
	if err := l.recorder.Sync(nil); err != nil {
		return httpapi.DiagnosticLogStatus{}, err
	}
	if err := l.recorder.WriteError(); err != nil {
		return httpapi.DiagnosticLogStatus{}, err
	}
	expires := l.recorder.ExpiresAt()
	if err := l.writer.prune(time.Now()); err != nil {
		return httpapi.DiagnosticLogStatus{}, err
	}
	w := l.writer
	w.mu.Lock()
	defer w.mu.Unlock()
	status := httpapi.DiagnosticLogStatus{Enabled: expires != nil, ExpiresAt: expires,
		CurrentBytes: w.size, MaxTotalBytes: 2 * w.maxBytes, RetentionDays: 7, DroppedRecords: l.recorder.Dropped()}
	info, err := os.Lstat(w.previous)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return status, err
	}
	if info != nil {
		status.PreviousBytes = info.Size()
	}
	status.TotalBytes = status.CurrentBytes + status.PreviousBytes
	if l.debugWriter != nil {
		bytes, err := l.debugWriter.totalBytes()
		if err != nil {
			return status, err
		}
		status.DebugBytes = bytes
		status.DebugDropped = l.debug.Dropped()
	}
	return status, nil
}

func (l *managedDiagnosticLogs) SetEnabled(enabled bool) (httpapi.DiagnosticLogStatus, error) {
	if enabled {
		l.recorder.Start()
	} else {
		if err := l.recorder.Stop(); err != nil {
			return httpapi.DiagnosticLogStatus{}, err
		}
	}
	return l.Status()
}

func (l *managedDiagnosticLogs) Clear() (httpapi.DiagnosticLogStatus, error) {
	if err := l.recorder.Sync(func() error {
		if err := l.writer.clear(); err != nil {
			return err
		}
		if l.debugWriter != nil {
			// 先让调试日志队列里已有的行写完，再截断；否则清除前排队的记录会在清除后被写回。
			if err := l.debug.Sync(l.debugWriter.clear); err != nil {
				return err
			}
		}
		l.recorder.ClearError()
		return nil
	}); err != nil {
		return httpapi.DiagnosticLogStatus{}, err
	}
	return l.Status()
}

func (l *managedDiagnosticLogs) Export() ([]string, error) {
	var lines []string
	err := l.recorder.Sync(func() error {
		if err := l.recorder.WriteError(); err != nil {
			return err
		}
		var err error
		lines, err = l.writer.export(time.Now())
		return err
	})
	return lines, err
}
