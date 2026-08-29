package setup

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/config"
)

// sshPreflight 是旧配置迁移前唯一允许写入新配置的前置检查。
// 测试可以替换它验证失败时的 CAS 不会发生；生产实现必须同时检查远端
// Codex 版本和真实 proxy WebSocket initialize。
var sshPreflight = func(ctx context.Context, transport *appserver.SSHTransport) error {
	if _, err := transport.CheckRemoteCodex(ctx); err != nil {
		return err
	}
	return transport.EnsureReady(ctx)
}

// MigrateAppServerToSSH 把旧 managed WebSocket 配置一次性改写为 SSH 配置。
// 它只在 SSH 预检成功后提交，提交使用原始 bytes 做 CAS，并保留根对象和
// app_server 中未识别的字段。shared_fallback、Unix/Desktop IPC 残留由 config
// 统一拒绝，不能通过这里恢复。
func MigrateAppServerToSSH(ctx context.Context, configPath string, requestedTarget string) error {
	path, err := resolveConfigPath(configPath)
	if err != nil {
		return err
	}
	info, err := os.Lstat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("读取配置文件状态失败：%w", err)
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("配置文件必须是 regular file，不能是目录或符号链接")
	}
	original, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("读取配置文件失败：%w", err)
	}
	if err := config.RejectLegacyAppServerConfiguration(original); err != nil {
		return err
	}

	document := map[string]json.RawMessage{}
	if err := json.Unmarshal(original, &document); err != nil {
		return fmt.Errorf("解析配置文件失败：%w", err)
	}
	if document == nil {
		return fmt.Errorf("配置文件必须是 JSON object")
	}
	rawAppServer, exists := document["app_server"]
	if !exists || string(rawAppServer) == "null" {
		return nil
	}
	appServer := map[string]json.RawMessage{}
	if err := json.Unmarshal(rawAppServer, &appServer); err != nil || appServer == nil {
		if err != nil {
			return fmt.Errorf("解析 app_server 配置失败：%w", err)
		}
		return fmt.Errorf("app_server 配置必须是 JSON object")
	}

	transportName := strings.ToLower(rawString(appServer["transport"]))
	legacy := hasAnyKey(appServer, "managed", "listen", "ws_token_file", "remote_gateway")
	if transportName == "ssh" && !legacy {
		return nil
	}
	if transportName != "" && transportName != "ws" {
		return fmt.Errorf("旧 app_server.transport=%q 不能自动迁移；请执行 agentd setup --force，并先关闭旧 Desktop/stdio 实验运行时", transportName)
	}
	if managed, ok := rawBool(appServer["managed"]); ok && !managed {
		return fmt.Errorf("旧 app_server.managed=false 不能自动迁移；请执行 agentd setup --force")
	}

	target := requestedTarget
	if strings.TrimSpace(target) == "" {
		target = rawString(appServer["ssh_target"])
	}
	if strings.TrimSpace(target) == "" {
		target = config.DefaultAppServerSSHTarget()
	}
	transport, err := appserver.NewSSHTransport(appserver.SSHTransportOptions{Target: target})
	if err != nil {
		return fmt.Errorf("app_server.ssh_target 无效：%w", err)
	}
	if err := sshPreflight(ctx, transport); err != nil {
		return fmt.Errorf("SSH 预检失败，原配置未修改：%w", err)
	}

	delete(appServer, "managed")
	delete(appServer, "listen")
	delete(appServer, "ws_token_file")
	delete(appServer, "remote_gateway")
	transportRaw, _ := json.Marshal(config.DefaultAppServerTransport())
	targetRaw, _ := json.Marshal(target)
	appServer["transport"] = transportRaw
	appServer["ssh_target"] = targetRaw
	encodedAppServer, err := json.Marshal(appServer)
	if err != nil {
		return fmt.Errorf("编码 app_server 配置失败：%w", err)
	}
	document["app_server"] = encodedAppServer
	updated, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		return fmt.Errorf("编码配置文件失败：%w", err)
	}
	updated = append(updated, '\n')

	return withConfigCommitLock(ctx, path, func() error {
		current, err := os.ReadFile(path)
		if err != nil {
			return fmt.Errorf("重新读取配置失败：%w", err)
		}
		if !bytes.Equal(current, original) {
			return fmt.Errorf("配置已被其他进程修改，请重新执行")
		}
		if err := writePrivateFileAtomically(path, updated); err != nil {
			return fmt.Errorf("原子迁移 app-server 配置失败：%w", err)
		}
		return nil
	})
}

func hasAnyKey(values map[string]json.RawMessage, keys ...string) bool {
	for _, key := range keys {
		if _, ok := values[key]; ok {
			return true
		}
	}
	return false
}

func rawString(raw json.RawMessage) string {
	var value string
	if len(raw) == 0 || json.Unmarshal(raw, &value) != nil {
		return ""
	}
	return strings.TrimSpace(value)
}

func rawBool(raw json.RawMessage) (bool, bool) {
	var value bool
	if len(raw) == 0 || json.Unmarshal(raw, &value) != nil {
		return false, false
	}
	return value, true
}
