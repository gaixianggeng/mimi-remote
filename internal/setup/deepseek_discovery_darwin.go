//go:build darwin

package setup

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

const (
	deepSeekLaunchAgentLabel = "ai.deepseek.harness.web"
	maxLaunchctlOutputBytes  = 256 << 10
	maxDeepSeekLogTailBytes  = 1 << 20
)

func discoverDeepSeekLaunchAgent(ctx context.Context) (deepSeekConnectionCandidate, error) {
	pid, stdoutPath, err := inspectDeepSeekLaunchAgent(ctx)
	if err != nil {
		return deepSeekConnectionCandidate{}, err
	}
	raw, err := readDeepSeekLogTail(stdoutPath)
	if err != nil {
		return deepSeekConnectionCandidate{}, errDeepSeekNotDiscovered
	}
	candidate, err := parseLastDeepSeekLaunchLine(raw)
	if err != nil {
		return deepSeekConnectionCandidate{}, errDeepSeekNotDiscovered
	}
	candidate.PID = pid
	if err := validateDiscoveredDeepSeekCandidate(candidate); err != nil {
		return deepSeekConnectionCandidate{}, errDeepSeekNotDiscovered
	}
	return candidate, nil
}

func currentDeepSeekLaunchAgentPID(ctx context.Context) (int, error) {
	pid, _, err := inspectDeepSeekLaunchAgent(ctx)
	return pid, err
}

func inspectDeepSeekLaunchAgent(ctx context.Context) (int, string, error) {
	target := fmt.Sprintf("gui/%d/%s", os.Getuid(), deepSeekLaunchAgentLabel)
	command := exec.CommandContext(ctx, "launchctl", "print", target)
	var stdout limitedDeepSeekBuffer
	stdout.limit = maxLaunchctlOutputBytes
	command.Stdout = &stdout
	command.Stderr = io.Discard
	if err := command.Run(); err != nil {
		return 0, "", errDeepSeekNotDiscovered
	}
	return parseDeepSeekLaunchctlPrint(stdout.Bytes())
}

type limitedDeepSeekBuffer struct {
	bytes.Buffer
	limit int
}

func (b *limitedDeepSeekBuffer) Write(raw []byte) (int, error) {
	if b.Len()+len(raw) > b.limit {
		return 0, errors.New("launchctl 输出超过安全上限")
	}
	return b.Buffer.Write(raw)
}

func parseDeepSeekLaunchctlPrint(raw []byte) (int, string, error) {
	var pid int
	var stdoutPath string
	running := false
	for _, rawLine := range strings.Split(string(raw), "\n") {
		// launchctl 的根 job 字段缩进一个 tab。嵌套块还会含 JSON（如 LWCR），
		// 不能只数“ = {”来判断层级，否则 JSON 的闭括号会把后续 pid 降到错误层。
		if !strings.HasPrefix(rawLine, "\t") || strings.HasPrefix(rawLine, "\t\t") {
			continue
		}
		line := strings.TrimSpace(rawLine)
		key, value, ok := strings.Cut(line, " = ")
		if ok {
			switch strings.TrimSpace(key) {
			case "state":
				running = strings.TrimSpace(value) == "running"
			case "pid":
				parsed, err := strconv.Atoi(strings.TrimSpace(value))
				if err == nil && parsed > 0 {
					pid = parsed
				}
			case "stdout path":
				stdoutPath = strings.TrimSpace(value)
			}
		}
	}
	if !running || pid <= 0 || stdoutPath == "" || !strings.HasPrefix(stdoutPath, "/") {
		return 0, "", errDeepSeekNotDiscovered
	}
	return pid, stdoutPath, nil
}

func readDeepSeekLogTail(path string) ([]byte, error) {
	declaredInfo, err := os.Lstat(path)
	if err != nil || !declaredInfo.Mode().IsRegular() {
		return nil, errDeepSeekNotDiscovered
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	openedInfo, err := file.Stat()
	if err != nil || !openedInfo.Mode().IsRegular() || !os.SameFile(declaredInfo, openedInfo) {
		return nil, errDeepSeekNotDiscovered
	}
	offset := openedInfo.Size() - maxDeepSeekLogTailBytes
	if offset < 0 {
		offset = 0
	}
	if _, err := file.Seek(offset, io.SeekStart); err != nil {
		return nil, err
	}
	raw, err := io.ReadAll(io.LimitReader(file, maxDeepSeekLogTailBytes))
	if err != nil {
		return nil, err
	}
	// 从文件中段开始时丢弃第一条残缺行，避免把任意字节误判成正式启动输出。
	if offset > 0 {
		if index := bytes.IndexByte(raw, '\n'); index >= 0 {
			raw = raw[index+1:]
		} else {
			return nil, errDeepSeekNotDiscovered
		}
	}
	return raw, nil
}

func parseLastDeepSeekLaunchLine(raw []byte) (deepSeekConnectionCandidate, error) {
	const prefix = "dsh web: "
	last := ""
	for _, rawLine := range strings.Split(string(raw), "\n") {
		line := strings.TrimSpace(rawLine)
		if strings.HasPrefix(line, prefix) {
			fields := strings.Fields(strings.TrimPrefix(line, prefix))
			if len(fields) > 0 && (strings.HasPrefix(fields[0], "http://") || strings.HasPrefix(fields[0], "https://")) {
				// 官方日志还会输出同前缀的浏览器提示，URL 后也可能附带 LAN 地址。
				// 只读取这条启动行的首个 URL，不能让提示文案覆盖已找到的凭据。
				last = fields[0]
			}
		}
	}
	if last == "" {
		return deepSeekConnectionCandidate{}, errDeepSeekNotDiscovered
	}
	return parseDeepSeekStartupURL(last)
}
