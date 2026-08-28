package setup

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

type configWriter func(path string, raw []byte) error
type renameFile func(oldPath string, newPath string) error

type privateFileStageOps struct {
	write func(file *os.File, raw []byte) (int, error)
	sync  func(file *os.File) error
}

// RepairManagedWSTokenFile 只修复托管 WS upstream 的独立 token，不重建整份配置。
// 调用方应先通过 Doctor 确认当前配置确实是 managed WS；这里保留原 JSON 中的
// auth、projects、actions 及未来新增字段，只更新 app_server.ws_token_file。
func RepairManagedWSTokenFile(configPath string) (string, bool, error) {
	return repairManagedWSTokenFile(configPath, nil)
}

// RepairRemoteGatewayTokenFile 只在 remote_gateway 已显式启用时补齐独立 token。
// 它保留未知配置字段，并且不会让 SSH/CLI 入口复用外侧或 upstream 凭据。
func RepairRemoteGatewayTokenFile(configPath string) (string, bool, error) {
	cfgPath, err := resolveConfigPath(configPath)
	if err != nil {
		return "", false, err
	}
	info, err := os.Lstat(cfgPath)
	if err != nil {
		return "", false, fmt.Errorf("读取配置文件状态失败：%w", err)
	}
	if !info.Mode().IsRegular() {
		return "", false, fmt.Errorf("配置文件必须是 regular file，不能是目录或符号链接")
	}
	original, err := os.ReadFile(cfgPath)
	if err != nil {
		return "", false, fmt.Errorf("读取配置文件失败：%w", err)
	}
	if err := config.RejectLegacyAppServerConfiguration(original); err != nil {
		return "", false, err
	}
	document, appServer, remote, enabled, tokenPath, err := decodeRemoteGatewayForTokenRepair(original)
	if err != nil || !enabled {
		return "", false, err
	}
	if tokenPath != "" {
		tokenInfo, statErr := os.Lstat(tokenPath)
		switch {
		case statErr == nil && !tokenInfo.Mode().IsRegular():
			return "", false, fmt.Errorf("remote gateway token file 必须是 regular file，不能是目录或符号链接：%s", tokenPath)
		case statErr == nil:
			return tokenPath, false, nil
		case !os.IsNotExist(statErr):
			return "", false, fmt.Errorf("读取 remote gateway token file 状态失败：%w", statErr)
		}
	}

	token, err := randomHex(32)
	if err != nil {
		return "", false, err
	}
	tokenPath, err = createPrivateNamedTokenFile(filepath.Dir(cfgPath), "remote-gateway-token-", token)
	if err != nil {
		return "", false, err
	}
	committed := false
	defer func() {
		if !committed {
			_ = os.Remove(tokenPath)
		}
	}()
	encodedPath, err := json.Marshal(tokenPath)
	if err != nil {
		return "", false, fmt.Errorf("编码 remote gateway token file 路径失败：%w", err)
	}
	remote["token_file"] = encodedPath
	encodedRemote, err := json.Marshal(remote)
	if err != nil {
		return "", false, fmt.Errorf("编码 app_server.remote_gateway 配置失败：%w", err)
	}
	appServer["remote_gateway"] = encodedRemote
	encodedAppServer, err := json.Marshal(appServer)
	if err != nil {
		return "", false, fmt.Errorf("编码 app_server 配置失败：%w", err)
	}
	document["app_server"] = encodedAppServer
	updated, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		return "", false, fmt.Errorf("编码配置文件失败：%w", err)
	}
	if err := writePrivateFileAtomicallyCAS(cfgPath, original, append(updated, '\n')); err != nil {
		return "", false, fmt.Errorf("原子更新配置文件失败：%w", err)
	}
	committed = true
	return tokenPath, true, nil
}

// RotateRemoteGatewayTokenFile 原子替换 SSH/CLI token。handler 每次握手重新读文件，
// 因此 rename 成功后旧 token 立即失效，不需要重启 agentd。
func RotateRemoteGatewayTokenFile(configPath string) (string, error) {
	cfgPath, err := resolveConfigPath(configPath)
	if err != nil {
		return "", err
	}
	raw, err := os.ReadFile(cfgPath)
	if err != nil {
		return "", fmt.Errorf("读取配置文件失败：%w", err)
	}
	_, _, _, enabled, tokenPath, err := decodeRemoteGatewayForTokenRepair(raw)
	if err != nil {
		return "", err
	}
	if !enabled {
		return "", fmt.Errorf("app_server.remote_gateway 尚未启用")
	}
	if tokenPath == "" {
		return "", fmt.Errorf("app_server.remote_gateway.token_file 为空；请先运行 agentd doctor --fix")
	}
	info, err := os.Lstat(tokenPath)
	if err != nil {
		return "", fmt.Errorf("读取 remote gateway token file 状态失败：%w", err)
	}
	if !info.Mode().IsRegular() {
		return "", fmt.Errorf("remote gateway token file 必须是 regular file，不能是目录或符号链接")
	}
	token, err := randomHex(32)
	if err != nil {
		return "", err
	}
	if err := writePrivateFileAtomically(tokenPath, []byte(token+"\n")); err != nil {
		return "", fmt.Errorf("原子轮换 remote gateway token 失败：%w", err)
	}
	return tokenPath, nil
}

func decodeRemoteGatewayForTokenRepair(raw []byte) (
	map[string]json.RawMessage,
	map[string]json.RawMessage,
	map[string]json.RawMessage,
	bool,
	string,
	error,
) {
	document, appServer, _, err := decodeConfigForTokenRepair(raw)
	if err != nil {
		return nil, nil, nil, false, "", err
	}
	remote := map[string]json.RawMessage{}
	if encoded, ok := appServer["remote_gateway"]; ok && string(encoded) != "null" {
		if err := json.Unmarshal(encoded, &remote); err != nil {
			return nil, nil, nil, false, "", fmt.Errorf("解析 app_server.remote_gateway 失败：%w", err)
		}
	}
	enabled := false
	if encoded, ok := remote["enabled"]; ok {
		if err := json.Unmarshal(encoded, &enabled); err != nil {
			return nil, nil, nil, false, "", fmt.Errorf("解析 app_server.remote_gateway.enabled 失败：%w", err)
		}
	}
	tokenPath := ""
	if encoded, ok := remote["token_file"]; ok {
		if err := json.Unmarshal(encoded, &tokenPath); err != nil {
			return nil, nil, nil, false, "", fmt.Errorf("解析 app_server.remote_gateway.token_file 失败：%w", err)
		}
		tokenPath = strings.TrimSpace(tokenPath)
	}
	return document, appServer, remote, enabled, tokenPath, nil
}

func repairManagedWSTokenFile(configPath string, writeConfig configWriter) (string, bool, error) {
	cfgPath, err := resolveConfigPath(configPath)
	if err != nil {
		return "", false, err
	}
	info, err := os.Lstat(cfgPath)
	if err != nil {
		return "", false, fmt.Errorf("读取配置文件状态失败：%w", err)
	}
	if !info.Mode().IsRegular() {
		return "", false, fmt.Errorf("配置文件必须是 regular file，不能是目录或符号链接")
	}

	original, err := os.ReadFile(cfgPath)
	if err != nil {
		return "", false, fmt.Errorf("读取配置文件失败：%w", err)
	}
	if err := config.RejectLegacyAppServerConfiguration(original); err != nil {
		return "", false, err
	}
	document, appServer, existingTokenPath, err := decodeConfigForTokenRepair(original)
	if err != nil {
		return "", false, err
	}
	if existingTokenPath != "" {
		tokenInfo, statErr := os.Lstat(existingTokenPath)
		switch {
		case statErr == nil && !tokenInfo.Mode().IsRegular():
			// 敏感文件绝不跟随 symlink，也不把目录静默替换成普通文件。
			return "", false, fmt.Errorf("app-server token file 必须是 regular file，不能是目录或符号链接：%s", existingTokenPath)
		case statErr == nil:
			return existingTokenPath, false, nil
		case !os.IsNotExist(statErr):
			return "", false, fmt.Errorf("读取 app-server token file 状态失败：%w", statErr)
		}
	}

	token, err := randomHex(32)
	if err != nil {
		return "", false, err
	}
	tokenPath, err := createPrivateTokenFile(filepath.Dir(cfgPath), token)
	if err != nil {
		return "", false, err
	}
	committed := false
	defer func() {
		if !committed {
			_ = os.Remove(tokenPath)
		}
	}()

	encodedPath, err := json.Marshal(tokenPath)
	if err != nil {
		return "", false, fmt.Errorf("编码 app-server token file 路径失败：%w", err)
	}
	appServer["ws_token_file"] = encodedPath
	encodedAppServer, err := json.Marshal(appServer)
	if err != nil {
		return "", false, fmt.Errorf("编码 app_server 配置失败：%w", err)
	}
	document["app_server"] = encodedAppServer
	updated, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		return "", false, fmt.Errorf("编码配置文件失败：%w", err)
	}
	updated = append(updated, '\n')

	// token 先以 O_EXCL 安全落盘，配置再以 rename 作为唯一提交点；提交失败会删除新 token，旧配置保持原样。
	var writeErr error
	if writeConfig == nil {
		writeErr = writePrivateFileAtomicallyCAS(cfgPath, original, updated)
	} else {
		writeErr = writeConfig(cfgPath, updated)
	}
	if writeErr != nil {
		return "", false, fmt.Errorf("原子更新配置文件失败：%w", writeErr)
	}
	committed = true
	return tokenPath, true, nil
}

func decodeConfigForTokenRepair(raw []byte) (map[string]json.RawMessage, map[string]json.RawMessage, string, error) {
	document := map[string]json.RawMessage{}
	if err := json.Unmarshal(raw, &document); err != nil {
		return nil, nil, "", fmt.Errorf("解析配置文件失败：%w", err)
	}
	if document == nil {
		return nil, nil, "", fmt.Errorf("配置文件必须是 JSON object")
	}

	appServer := map[string]json.RawMessage{}
	if rawAppServer, ok := document["app_server"]; ok && string(rawAppServer) != "null" {
		if err := json.Unmarshal(rawAppServer, &appServer); err != nil {
			return nil, nil, "", fmt.Errorf("解析 app_server 配置失败：%w", err)
		}
		if appServer == nil {
			appServer = map[string]json.RawMessage{}
		}
	}

	existingTokenPath := ""
	if rawTokenPath, ok := appServer["ws_token_file"]; ok {
		if err := json.Unmarshal(rawTokenPath, &existingTokenPath); err != nil {
			return nil, nil, "", fmt.Errorf("解析 app_server.ws_token_file 失败：%w", err)
		}
		existingTokenPath = strings.TrimSpace(existingTokenPath)
	}
	return document, appServer, existingTokenPath, nil
}

func createPrivateTokenFile(dir string, token string) (string, error) {
	return createPrivateNamedTokenFile(dir, "app-server-ws-token-", token)
}

func createPrivateNamedTokenFile(dir string, pattern string, token string) (string, error) {
	path, err := stagePrivateFile(dir, pattern, []byte(token+"\n"))
	if err != nil {
		return "", fmt.Errorf("创建 app-server token file 失败：%w", err)
	}
	return path, nil
}

func writePrivateFileAtomically(path string, raw []byte) error {
	return writePrivateFileAtomicallyWithRename(path, raw, os.Rename)
}

func writePrivateFileAtomicallyCAS(path string, expected []byte, raw []byte) error {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	return withConfigCommitLock(ctx, path, func() error {
		current, err := os.ReadFile(path)
		if err != nil {
			return fmt.Errorf("重新读取配置失败：%w", err)
		}
		if !bytes.Equal(current, expected) {
			return fmt.Errorf("配置已被其他进程修改，请重新执行")
		}
		return writePrivateFileAtomically(path, raw)
	})
}

func writePrivateFileAtomicallyWithRename(path string, raw []byte, rename renameFile) error {
	dir := filepath.Dir(path)
	tempPath, err := stagePrivateFile(dir, ".config.json.tmp-", raw)
	if err != nil {
		return err
	}
	defer os.Remove(tempPath)
	if err := rename(tempPath, path); err != nil {
		return err
	}

	// rename 已经是配置的提交点；目录 fsync 只做尽力而为，避免提交成功后因平台差异反报失败。
	if dirFile, openErr := os.Open(dir); openErr == nil {
		_ = dirFile.Sync()
		_ = dirFile.Close()
	}
	return nil
}

func stagePrivateFile(dir string, pattern string, raw []byte) (string, error) {
	return stagePrivateFileWithOps(dir, pattern, raw, privateFileStageOps{
		write: func(file *os.File, raw []byte) (int, error) {
			return file.Write(raw)
		},
		sync: func(file *os.File) error {
			return file.Sync()
		},
	})
}

func stagePrivateFileWithOps(dir string, pattern string, raw []byte, ops privateFileStageOps) (string, error) {
	file, err := os.CreateTemp(dir, pattern)
	if err != nil {
		return "", err
	}
	path := file.Name()
	complete := false
	defer func() {
		_ = file.Close()
		if !complete {
			_ = os.Remove(path)
		}
	}()

	if err := makePrivateFile(file); err != nil {
		return "", err
	}
	written, err := ops.write(file, raw)
	if err != nil {
		return "", err
	}
	if written != len(raw) {
		return "", io.ErrShortWrite
	}
	if err := ops.sync(file); err != nil {
		return "", err
	}
	if err := file.Close(); err != nil {
		return "", err
	}
	complete = true
	return path, nil
}
