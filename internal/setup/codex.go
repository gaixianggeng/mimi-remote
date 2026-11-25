package setup

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

type codexBinResolver func(configured string) (string, error)

// ResolveCodexBin returns a compatible local Codex executable.
func ResolveCodexBin(configured string) (string, error) {
	candidate, err := ResolveRuntime(context.Background(), RuntimeRequest{Name: "codex", Pin: configured})
	return candidate.Path, err
}

// An explicit repair or legacy transport migration can recover a stale path.
func (d RuntimeDiscovery) repairCodex(parent context.Context, req RuntimeRequest) (RuntimeCandidate, error) {
	ctx, cancel := d.timeout(parent, 20*time.Second)
	defer cancel()
	result, err := d.Resolve(ctx, req)
	// A failed search or probe cannot establish that a saved file is gone.
	if result.Source == "pin" && result.Path == "" && filepath.Base(req.Pin) != req.Pin &&
		errors.Is(err, os.ErrNotExist) && ctx.Err() == nil {
		req.Pin = ""
		result, err = d.Resolve(ctx, req)
	}
	return result, err
}

func darwinCodexCandidates(home string) []string {
	candidates := []string{
		"/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
		"/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
		"/Applications/ChatGPT.app/Contents/Resources/codex",
		"/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
		"/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
		"/Applications/Codex.app/Contents/Resources/codex",
	}
	if home != "" {
		candidates = append(candidates,
			filepath.Join(home, "Applications", "ChatGPT.app", "Contents", "Resources", "codex-cli", "bin", "codex"),
			filepath.Join(home, "Applications", "ChatGPT.app", "Contents", "Resources", "codex-cli", "CodexCLI.app", "Contents", "MacOS", "codex"),
			filepath.Join(home, "Applications", "ChatGPT.app", "Contents", "Resources", "codex"),
			filepath.Join(home, "Applications", "Codex.app", "Contents", "Resources", "codex-cli", "bin", "codex"),
			filepath.Join(home, "Applications", "Codex.app", "Contents", "Resources", "codex-cli", "CodexCLI.app", "Contents", "MacOS", "codex"),
			filepath.Join(home, "Applications", "Codex.app", "Contents", "Resources", "codex"),
		)
	}
	candidates = append(candidates,
		"/opt/homebrew/bin/codex",
		"/usr/local/bin/codex",
	)
	if home != "" {
		candidates = append(candidates,
			filepath.Join(home, ".local", "bin", "codex"),
			filepath.Join(home, ".npm-global", "bin", "codex"),
			filepath.Join(home, ".local", "share", "mise", "shims", "codex"),
			filepath.Join(home, ".local", "share", "mise", "installs", "codex", "latest", "bin", "codex"),
		)
	}
	return candidates
}

// applyResolvedCodexBin 用共享的回退解析器确定当前可用的 Codex 路径，与配置不同时写回
// document 的 codex.bin。doctor 修复与 transport 迁移都只经由这里维护该字段：迁移可以把
// 修好的路径和新 transport 放进同一次原子提交，而不必各自实现一份解析与写回。
func applyResolvedCodexBin(ctx context.Context, document map[string]json.RawMessage, req RuntimeRequest, resolve codexBinResolver) (string, bool, error) {
	codex := map[string]json.RawMessage{}
	if rawCodex, ok := document["codex"]; ok && string(rawCodex) != "null" {
		if err := json.Unmarshal(rawCodex, &codex); err != nil {
			return "", false, fmt.Errorf("解析 codex 配置失败：%w", err)
		}
		if codex == nil {
			codex = map[string]json.RawMessage{}
		}
	}
	configured := "codex"
	if rawBin, ok := codex["bin"]; ok {
		if err := json.Unmarshal(rawBin, &configured); err != nil {
			return "", false, fmt.Errorf("解析 codex.bin 失败：%w", err)
		}
		configured = strings.TrimSpace(configured)
		if configured == "" {
			configured = "codex"
		}
	}

	req.Pin = configured
	var candidate RuntimeCandidate
	var err error
	if resolve == nil {
		candidate, err = NewRuntimeDiscovery().repairCodex(ctx, req)
	} else {
		candidate.Path, err = resolve(configured)
	}
	if err != nil {
		return "", false, err
	}
	resolved := candidate.Path
	if resolved == configured || configured == "codex" || candidate.Source == "env" {
		return resolved, false, nil
	}

	encodedBin, err := json.Marshal(resolved)
	if err != nil {
		return "", false, fmt.Errorf("编码 codex.bin 失败：%w", err)
	}
	codex["bin"] = encodedBin
	encodedCodex, err := json.Marshal(codex)
	if err != nil {
		return "", false, fmt.Errorf("编码 codex 配置失败：%w", err)
	}
	document["codex"] = encodedCodex
	return resolved, true, nil
}

// RepairCodexBin 只更新 codex.bin，并保留 auth、projects 及未来新增字段。
// 写入复用私有文件的原子替换逻辑，避免修复中断后留下半份配置或放宽权限。
func RepairCodexBin(configPath string) (string, bool, error) {
	return repairCodexBin(configPath, nil, nil)
}

func repairCodexBin(configPath string, resolve codexBinResolver, writeConfig configWriter) (string, bool, error) {
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
	document := map[string]json.RawMessage{}
	if err := json.Unmarshal(original, &document); err != nil {
		return "", false, fmt.Errorf("解析配置文件失败：%w", err)
	}
	if document == nil {
		return "", false, fmt.Errorf("配置文件必须是 JSON object")
	}

	var saved struct {
		Codex     config.CodexConfig     `json:"codex"`
		AppServer config.AppServerConfig `json:"app_server"`
	}
	if err := json.Unmarshal(original, &saved); err != nil {
		return "", false, err
	}
	req := CodexRuntime(saved.Codex, strings.ToLower(strings.TrimSpace(saved.AppServer.Transport)))
	resolved, changed, err := applyResolvedCodexBin(context.Background(), document, req, resolve)
	if err != nil {
		return "", false, err
	}
	if !changed {
		return resolved, false, nil
	}
	updated, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		return "", false, fmt.Errorf("编码配置文件失败：%w", err)
	}
	updated = append(updated, '\n')
	var writeErr error
	if writeConfig == nil {
		validateOriginal := func() error {
			current, readErr := os.ReadFile(cfgPath)
			if readErr != nil {
				return fmt.Errorf("重新读取配置失败：%w", readErr)
			}
			if !bytes.Equal(current, original) {
				return fmt.Errorf("配置已被其他进程修改，请重新执行")
			}
			return nil
		}
		commitCtx, cancelCommit := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancelCommit()
		writeErr = withConfigCommitLock(commitCtx, cfgPath, func() error {
			if err := validateOriginal(); err != nil {
				return err
			}
			// 已在统一配置锁内完成原始字节复核，不能再调用会重复获取同一把锁的 CAS 写入。
			return writePrivateFileAtomically(cfgPath, updated)
		})
	} else {
		writeErr = writeConfig(cfgPath, updated)
	}
	if writeErr != nil {
		return "", false, fmt.Errorf("原子更新配置文件失败：%w", writeErr)
	}
	return resolved, true, nil
}
