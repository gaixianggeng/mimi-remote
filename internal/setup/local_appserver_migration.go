package setup

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

// MigrateAppServerToSharedLocal replaces the Linux-only managed WebSocket
// upstream with Codex's standard control socket. The resident is initialized
// before the existing file is changed, and the final write uses byte-level CAS.
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
	// Linux 的显式 SSH target 是受支持的高级模式，不能被默认迁移覆盖。
	if (transportName == "ssh" || transportName == "") && !legacy {
		return nil
	}
	if transportName != "" && transportName != "ws" {
		return fmt.Errorf("旧 app_server.transport=%q 不能自动迁移；请执行 agentd setup --force", transportName)
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
	codexBin := strings.TrimSpace(runtimeConfig.Codex.Bin)
	if codexBin == "" {
		codexBin = defaultCodexBin()
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
