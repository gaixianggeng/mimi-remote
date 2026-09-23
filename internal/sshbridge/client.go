package sshbridge

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
	"time"
)

// Run 转发一个 SSH exec 请求。返回后调用方需关闭自己持有的 stdin，
// 避免输入尚未结束时残留阻塞的读取协程；CLI 退出会自动关闭标准输入。
func Run(ctx context.Context, path, command string, stdin io.Reader, stdout, stderr io.Writer) (int, error) {
	if strings.TrimSpace(command) == "" || strings.ContainsRune(command, 0) || len(command) > maxFrame {
		return 0, errors.New("SSH 接入只支持非空的 exec 命令，不支持交互式登录")
	}
	dialer := net.Dialer{Timeout: 4 * time.Second}
	conn, err := dialer.DialContext(ctx, "unix", path)
	if err != nil {
		return 0, fmt.Errorf("Mimi 的专用 SSH 入口不可用，请启动已启用此入口的 Mimi Remote Mac：%w", err)
	}
	defer conn.Close()
	if err := validatePeer(conn); err != nil {
		return 0, err
	}
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	w := &frameWriter{w: conn}
	if err := w.send(frameCommand, []byte(command)); err != nil {
		return 0, err
	}
	go func() {
		buffer := make([]byte, 32<<10)
		for {
			n, err := stdin.Read(buffer)
			if n > 0 {
				if sendErr := w.send(frameInput, buffer[:n]); sendErr != nil {
					return
				}
			}
			if err != nil {
				if errors.Is(err, io.EOF) {
					_ = w.send(frameEOF, nil)
				} else {
					_ = conn.Close()
				}
				return
			}
		}
	}()
	for {
		kind, data, err := readFrame(conn)
		if err != nil {
			return 0, fmt.Errorf("Mimi SSH 命令连接中断：%w", err)
		}
		switch kind {
		case frameOutput, frameStderr:
			destination := stdout
			if kind == frameStderr {
				destination = stderr
			}
			if _, err := io.Copy(destination, bytes.NewReader(data)); err != nil {
				return 0, err
			}
		case frameExit:
			if len(data) != 4 || binary.BigEndian.Uint32(data) > 255 {
				return 0, errors.New("Mimi SSH 退出状态无效")
			}
			return int(binary.BigEndian.Uint32(data)), nil
		default:
			return 0, errors.New("Mimi SSH 响应类型无效")
		}
	}
}
