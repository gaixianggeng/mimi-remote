package main

import (
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"sync"
)

const defaultManagedLogMaxBytes int64 = 5 * 1024 * 1024

// rotatingLogWriter 为 Mac App 内嵌 LaunchAgent 提供有上限的私有日志文件。
// 只保留当前文件和一份 previous，避免常驻服务长期占满用户磁盘。
type rotatingLogWriter struct {
	mu       sync.Mutex
	path     string
	previous string
	maxBytes int64
	file     *os.File
	size     int64
}

func newRotatingLogWriter(path string, maxBytes int64) (*rotatingLogWriter, error) {
	path = filepath.Clean(expandUserPath(path))
	if path == "." || path == "" {
		return nil, fmt.Errorf("日志文件路径不能为空")
	}
	if maxBytes <= 0 {
		return nil, fmt.Errorf("日志文件上限必须大于 0")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, fmt.Errorf("创建日志目录失败：%w", err)
	}
	writer := &rotatingLogWriter{
		path:     path,
		previous: path + ".previous",
		maxBytes: maxBytes,
	}
	if err := writer.open(); err != nil {
		return nil, err
	}
	if writer.size >= writer.maxBytes {
		if err := writer.rotate(); err != nil {
			_ = writer.file.Close()
			return nil, err
		}
	}
	return writer, nil
}

func (w *rotatingLogWriter) open() error {
	if info, err := os.Lstat(w.path); err == nil {
		if !info.Mode().IsRegular() {
			return fmt.Errorf("日志路径必须是普通文件，不能是目录或符号链接：%s", w.path)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("检查日志文件失败：%w", err)
	}
	file, err := os.OpenFile(w.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return fmt.Errorf("打开日志文件失败：%w", err)
	}
	if err := file.Chmod(0o600); err != nil {
		_ = file.Close()
		return fmt.Errorf("收紧日志文件权限失败：%w", err)
	}
	info, err := file.Stat()
	if err != nil {
		_ = file.Close()
		return fmt.Errorf("读取日志文件状态失败：%w", err)
	}
	w.file = file
	w.size = info.Size()
	return nil
}

func (w *rotatingLogWriter) Write(data []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.file == nil {
		return 0, os.ErrClosed
	}
	if w.size > 0 && w.size+int64(len(data)) > w.maxBytes {
		if err := w.rotate(); err != nil {
			return 0, err
		}
	}
	payload := data
	if int64(len(payload)) > w.maxBytes {
		// 单条异常大日志也不能突破磁盘上限；保留末尾通常更有诊断价值。
		payload = payload[len(payload)-int(w.maxBytes):]
	}
	written, err := w.file.Write(payload)
	w.size += int64(written)
	if err != nil {
		return written, err
	}
	return len(data), nil
}

func (w *rotatingLogWriter) rotate() error {
	if w.file != nil {
		if err := w.file.Close(); err != nil {
			return fmt.Errorf("关闭待轮转日志失败：%w", err)
		}
		w.file = nil
	}
	if err := os.Remove(w.previous); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("清理旧日志失败：%w", err)
	}
	if err := os.Rename(w.path, w.previous); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("轮转日志失败：%w", err)
	}
	return w.open()
}

func (w *rotatingLogWriter) Close() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.file == nil {
		return nil
	}
	err := w.file.Close()
	w.file = nil
	return err
}

func configureServeFileLogging(path string) (func(), error) {
	if path == "" {
		return nil, nil
	}
	writer, err := newRotatingLogWriter(path, defaultManagedLogMaxBytes)
	if err != nil {
		return nil, err
	}
	previous := log.Writer()
	log.SetOutput(io.MultiWriter(previous, writer))
	return func() {
		log.SetOutput(previous)
		_ = writer.Close()
	}, nil
}
