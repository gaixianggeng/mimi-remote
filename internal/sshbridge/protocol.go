// Package sshbridge 将已通过系统 SSH 认证的命令交给当前用户的 GUI agentd。
// 它只负责本机命令转发，不实现 SSH 服务或 Codex 协议。
package sshbridge

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"sync"
)

const maxFrame = 256 << 10

const (
	frameCommand byte = 'C'
	frameInput   byte = 'I'
	frameEOF     byte = 'E'
	frameOutput  byte = 'O'
	frameStderr  byte = 'R'
	frameExit    byte = 'X'
)

func readFrame(r io.Reader) (byte, []byte, error) {
	var header [5]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return 0, nil, err
	}
	size := binary.BigEndian.Uint32(header[1:])
	if size > maxFrame {
		return 0, nil, errors.New("SSH 命令转发数据超过上限")
	}
	data := make([]byte, size)
	_, err := io.ReadFull(r, data)
	return header[0], data, err
}

type frameWriter struct {
	mu sync.Mutex
	w  io.Writer
}

func (w *frameWriter) send(kind byte, data []byte) error {
	if len(data) > maxFrame {
		return errors.New("SSH 命令转发数据超过上限")
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	var header [5]byte
	header[0] = kind
	binary.BigEndian.PutUint32(header[1:], uint32(len(data)))
	if _, err := io.Copy(w.w, bytes.NewReader(header[:])); err != nil {
		return err
	}
	_, err := io.Copy(w.w, bytes.NewReader(data))
	return err
}

type streamWriter struct {
	writer *frameWriter
	kind   byte
}

func (w streamWriter) Write(p []byte) (int, error) {
	if err := w.writer.send(w.kind, p); err != nil {
		return 0, err
	}
	return len(p), nil
}
