package setup

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"runtime"
	"strings"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

// resolveMigrationCodexBin 是迁移使用的 Codex 路径解析器，与 doctor 修复相同；测试可替换。
var resolveMigrationCodexBin = ResolveCodexBin

// MigrateAppServerToSharedLocal replaces the former managed WebSocket upstream
// with Codex's standard control socket. On macOS it also rewrites the loopback
// SSH default that older setups wrote automatically. Platform-specific preflight
// runs before the file changes (static only on macOS); the write uses byte-level CAS.
func MigrateAppServerToSharedLocal(ctx context.Context, configPath string) error {
	return MigrateAppServerToSharedLocalWithPreflight(ctx, configPath, localAppServerPreflight)
}

// MigrateAppServerToSharedLocalWithPreflight exposes the transaction boundary
// to command-level tests; production callers use MigrateAppServerToSharedLocal.
func MigrateAppServerToSharedLocalWithPreflight(
	ctx context.Context,
	configPath string,
	preflight func(context.Context, string, map[string]string) error,
) error {
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
	if transportName == "local" && !legacy {
		return nil
	}
	// 用户显式固定的 transport（agentd up --app-server-ssh-target …）不属于历史默认值。
	if pinned, ok := rawBool(appServer["pin_transport"]); ok && pinned && !legacy {
		return nil
	}
	// 显式 SSH target 是受支持的远端模式，不能被默认迁移覆盖。macOS 旧版 setup
	// 自动写入的裸 127.0.0.1 不代表用户选择，直连预检通过后改为 local。
	migrateLoopbackSSH := !legacy && migratesLoopbackSSHToSharedLocal(transportName, rawString(appServer["ssh_target"]))
	if (transportName == "ssh" || transportName == "") && !legacy && !migrateLoopbackSSH {
		return nil
	}
	if !migrateLoopbackSSH && transportName != "" && transportName != "ws" {
		return fmt.Errorf("旧 app_server.transport=%q 不能自动迁移：%w", transportName, config.AppServerTransportError(transportName))
	}
	if managed, ok := rawBool(appServer["managed"]); ok && !managed {
		return fmt.Errorf("旧 app_server.managed=false 不能自动迁移；请执行 agentd setup --force")
	}

	var runtimeConfig struct {
		Codex config.CodexConfig `json:"codex"`
	}
	if err := json.Unmarshal(original, &runtimeConfig); err != nil {
		return fmt.Errorf("解析 Codex 配置失败：%w", err)
	}
	// 老安装的 codex.bin 可能已失效（桌面 App 移动或卸载），而 start/serve 的路径修复排在
	// 迁移之后。这里复用 doctor 修复同一个解析与写回逻辑：用回退解析出的路径做预检，
	// 修好的 codex.bin 和新 transport 进入同一次原子提交，不留"transport 已改、路径还坏"的中间态。
	codexBin, _, err := applyResolvedCodexBin(document, resolveMigrationCodexBin)
	if err != nil {
		return fmt.Errorf("共享本机 App Server 预检失败，原配置未修改：%w", err)
	}
	if preflight == nil {
		return fmt.Errorf("共享本机 App Server preflight 未配置")
	}
	if err := preflight(ctx, codexBin, runtimeConfig.Codex.Env); err != nil {
		return fmt.Errorf("共享本机 App Server 预检失败，原配置未修改：%w", err)
	}

	delete(appServer, "managed")
	delete(appServer, "listen")
	delete(appServer, "ws_token_file")
	delete(appServer, "remote_gateway")
	delete(appServer, "ssh_target")
	transportRaw, _ := json.Marshal("local")
	appServer["transport"] = transportRaw
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

// migratesLoopbackSSHToSharedLocal 只把 macOS 上无用户名的本机回环 SSH target 视为
// 旧默认值。带用户名的 target 会改变运行身份，远端主机则是明确的高级选择，二者都保留。
func migratesLoopbackSSHToSharedLocal(transportName string, sshTarget string) bool {
	if runtime.GOOS != "darwin" || transportName != "ssh" {
		return false
	}
	value := strings.ToLower(strings.TrimSpace(sshTarget))
	if value == "" || strings.Contains(value, "@") {
		return value == ""
	}
	value = strings.Trim(value, "[]")
	if value == "localhost" {
		return true
	}
	ip := net.ParseIP(value)
	return ip != nil && ip.IsLoopback()
}
