//go:build darwin

package appserver

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// CLI 升级会替换启动路径的符号链接。必须检查进程仍映射的旧文件，
// 不能用 argv 中的路径执行新版 --version，误判旧进程的退出能力。
func darwinMappedCodexExecutable(ctx context.Context, pid int) (string, error) {
	commandCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	cmd := exec.CommandContext(commandCtx, "/usr/sbin/lsof", "-nP", "-a", "-p", strconv.Itoa(pid), "-d", "txt", "-F0pn")
	output := cappedSharedLocalRepairBuffer{limit: sharedLocalRepairLsofOutputCap}
	cmd.Stdout = &output
	cmd.Stderr = io.Discard
	if err := cmd.Run(); err != nil {
		return "", errors.New("无法读取 Codex 实际加载的文件")
	}
	return mappedCodexExecutable(output.Bytes(), pid)
}

func mappedCodexExecutable(output []byte, pid int) (string, error) {
	owned := false
	path := ""
	for _, record := range bytes.Split(output, []byte{0}) {
		record = bytes.TrimLeft(record, "\n")
		if len(record) == 0 {
			continue
		}
		switch record[0] {
		case 'p':
			if string(record[1:]) != strconv.Itoa(pid) {
				return "", errors.New("Codex 映射文件的进程身份不一致")
			}
			owned = true
		case 'n':
			if !owned {
				return "", errors.New("Codex 映射文件缺少进程归属")
			}
			candidate := string(record[1:])
			// 官方单文件发行包保留平台后缀，安装器包则使用 bin/codex。
			switch filepath.Base(candidate) {
			case "codex", "codex-aarch64-apple-darwin", "codex-x86_64-apple-darwin":
			default:
				continue
			}
			if !filepath.IsAbs(candidate) || strings.ContainsAny(candidate, "\r\n") {
				return "", errors.New("Codex 映射文件路径无效")
			}
			if path != "" && path != candidate {
				return "", errors.New("无法唯一确认 Codex 映射文件")
			}
			path = candidate
		}
	}
	if path == "" {
		return "", errors.New("未找到 Codex 实际加载的文件")
	}
	return path, nil
}
