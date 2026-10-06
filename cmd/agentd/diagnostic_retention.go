package main

import (
	"bufio"
	"errors"
	"io"
	"os"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/diagnosticlog"
)

const diagnosticRetention = 7 * 24 * time.Hour

// 文件读写、裁剪和清空复用 writer 的互斥锁；清理不会替换活动文件句柄。
func (w *rotatingLogWriter) prune(now time.Time) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.file == nil {
		return os.ErrClosed
	}
	for _, path := range []string{w.previous, w.path} {
		lines, err := w.retainedLines(path, now, true)
		if err != nil {
			return err
		}
		data := strings.Join(lines, "\n")
		if len(lines) > 0 {
			data += "\n"
		}
		if path == w.path {
			if err := w.truncateActive(); err != nil {
				return err
			}
			n, err := w.file.Write([]byte(data))
			w.size = int64(n)
			if err != nil {
				return err
			}
		} else if len(data) == 0 {
			if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
				return err
			}
		} else {
			if err := os.WriteFile(path, []byte(data), 0o600); err != nil {
				return err
			}
			if err := os.Chmod(path, 0o600); err != nil {
				return err
			}
		}
	}
	return nil
}

// safeLines 同时约束读取体积、单行长度和记录年龄，旧自由文本不会进入用户报告。
func (w *rotatingLogWriter) safeLines(path string, now time.Time) ([]string, error) {
	return w.retainedLines(path, now, false)
}

func (w *rotatingLogWriter) retainedLines(path string, now time.Time, includeLegacy bool) ([]string, error) {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() {
		return nil, errors.New("日志路径不是普通文件")
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	// 旧版本或外部写入留下的超大文件也只能读取最新容量窗口。
	if info.Size() > w.maxBytes {
		if _, err := file.Seek(info.Size()-w.maxBytes, io.SeekStart); err != nil {
			return nil, err
		}
	}
	scanner := bufio.NewScanner(io.LimitReader(file, w.maxBytes))
	scanner.Buffer(make([]byte, 4096), int(w.maxBytes)+1)
	lines := []string{}
	for scanner.Scan() {
		if len(scanner.Bytes()) > 2048 && !includeLegacy {
			continue
		}
		var event diagnosticlog.Event
		ok := false
		if len(scanner.Bytes()) <= 2048 {
			event, ok = diagnosticlog.Parse(scanner.Text())
		}
		if !ok && includeLegacy {
			// 升级时保留可按时间裁剪的旧日志，但旧原文永不进入安全导出。
			if at, valid := legacyLogTime(scanner.Text()); valid && !at.Before(now.Add(-diagnosticRetention)) && !at.After(now.Add(time.Minute)) {
				lines = append(lines, scanner.Text())
			}
			continue
		}
		// 容忍读写取时之间的微小竞态；远期伪造时间不能让记录永久保留。
		if !ok || event.At.Before(now.Add(-diagnosticRetention)) || event.At.After(now.Add(time.Minute)) {
			continue
		}
		line, ok := diagnosticlog.Format(event)
		if ok {
			lines = append(lines, line)
		}
	}
	// 重新编码或补换行也不能让迁移后的文件越过容量边界。
	var retainedBytes int64
	for i := len(lines) - 1; i >= 0; i-- {
		retainedBytes += int64(len(lines[i]) + 1)
		if retainedBytes > w.maxBytes {
			lines = lines[i+1:]
			break
		}
	}
	return lines, scanner.Err()
}

func legacyLogTime(line string) (time.Time, bool) {
	if len(line) >= 19 {
		if at, err := time.ParseInLocation("2006/01/02 15:04:05", line[:19], time.Local); err == nil {
			return at, true
		}
	}
	if prefix, _, ok := strings.Cut(line, " "); ok {
		if at, err := time.Parse(time.RFC3339Nano, prefix); err == nil {
			return at, true
		}
	}
	return time.Time{}, false
}

func (w *rotatingLogWriter) clear() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.file == nil {
		return os.ErrClosed
	}
	if err := os.Remove(w.previous); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := w.truncateActive(); err != nil {
		return err
	}
	w.size = 0
	return nil
}

// Windows 的 O_APPEND 句柄只有 FILE_APPEND_DATA 权限，不能直接 Truncate。
// 另开可截断的句柄并核对文件身份，既保留追加语义，也不误清路径被替换后的文件。
// 调用者必须持有 w.mu。
func (w *rotatingLogWriter) truncateActive() error {
	current, err := w.file.Stat()
	if err != nil {
		return err
	}
	file, err := os.OpenFile(w.path, os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return err
	}
	if !os.SameFile(current, info) {
		return errors.New("活动日志文件已被替换")
	}
	return file.Truncate(0)
}

func (w *rotatingLogWriter) export(now time.Time) ([]string, error) {
	if err := w.prune(now); err != nil {
		return nil, err
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	lines := []string{}
	for _, path := range []string{w.previous, w.path} {
		recent, err := w.safeLines(path, now)
		if err != nil {
			return nil, err
		}
		lines = append(lines, recent...)
	}
	return lines, nil
}
