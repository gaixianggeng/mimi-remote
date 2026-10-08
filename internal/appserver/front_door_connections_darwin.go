//go:build darwin

package appserver

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// CodexRuntimeConnections 只用于操作提示。不能用快照代替切换时的锁和进程身份检查。
type CodexRuntimeConnections struct {
	Mimi  int `json:"mimi"`
	Codex int `json:"codex"`
	Other int `json:"other"`
}

func (f *FrontDoor) RuntimeConnections(ctx context.Context) *CodexRuntimeConnections {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	// 只读当前用户的 Unix socket；不向产品界面暴露 PID、路径和进程参数。
	cmd := exec.CommandContext(ctx, "/usr/sbin/lsof", "-nP", "-a", "-U", "-u", strconv.Itoa(os.Getuid()), "-F0pcfdtn")
	output := cappedSharedLocalRepairBuffer{limit: 256 << 10}
	cmd.Stdout, cmd.Stderr = &output, io.Discard
	if err := cmd.Run(); err != nil {
		return nil
	}
	connections, err := frontDoorConnections(output.Bytes(), f.public)
	if err != nil {
		return nil
	}
	return &connections
}

func frontDoorConnections(output []byte, publicSocket string) (CodexRuntimeConnections, error) {
	type socketFile struct {
		pid, command, kind, address, name string
	}
	var files []socketFile
	var current socketFile
	hasFile := false
	flush := func() {
		if hasFile && current.kind == "unix" {
			files = append(files, current)
		}
	}
	for _, raw := range bytes.Split(output, []byte{0}) {
		field := strings.TrimLeft(string(raw), "\n")
		if field == "" {
			continue
		}
		value := field[1:]
		switch field[0] {
		case 'p':
			flush()
			pid, err := strconv.Atoi(value)
			if err != nil || pid <= 1 {
				return CodexRuntimeConnections{}, errors.New("连接快照缺少进程归属")
			}
			current, hasFile = socketFile{pid: value}, false
		case 'c':
			current.command = value
		case 'f':
			flush()
			if current.pid == "" || current.command == "" {
				return CodexRuntimeConnections{}, errors.New("连接快照缺少进程信息")
			}
			current = socketFile{pid: current.pid, command: current.command}
			hasFile = true
		case 't':
			current.kind = value
		case 'd':
			current.address = value
		case 'n':
			current.name = value
		}
	}
	flush()
	addresses := map[string]bool{}
	for _, file := range files {
		if file.name == publicSocket && strings.HasPrefix(file.address, "0x") {
			addresses[file.address] = true
		}
	}
	if len(addresses) == 0 {
		return CodexRuntimeConnections{}, errors.New("无法识别共享入口，不能报告没有连接")
	}
	counts := CodexRuntimeConnections{}
	seen := map[string]bool{}
	for _, file := range files {
		peer, ok := strings.CutPrefix(file.name, "->")
		if !ok || !addresses[peer] {
			continue
		}
		if !strings.HasPrefix(file.address, "0x") {
			return CodexRuntimeConnections{}, errors.New("无法识别共享连接")
		}
		// 同一 socket 可能被 dup 或由子进程继承，只计算一次。
		if seen[file.address] {
			continue
		}
		seen[file.address] = true
		switch file.command {
		case "agentd":
			counts.Mimi++
		case "codex", "codex-aarch64-apple-darwin", "codex-x86_64-apple-darwin":
			counts.Codex++
		default:
			counts.Other++
		}
	}
	return counts, nil
}
