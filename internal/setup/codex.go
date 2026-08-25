package setup

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
)

type codexBinResolver func(configured string) (string, error)
type executableLookup func(file string) (string, error)

// ResolveCodexBin 返回当前机器可执行的 Codex 绝对路径。配置中的路径优先；旧路径
// 失效时才回退到当前 PATH 和桌面 App 内置二进制，避免 Homebrew service 因 PATH
// 比交互式终端更窄而启动失败。
func ResolveCodexBin(configured string) (string, error) {
	return resolveCodexBin(configured, lookupUsableCodexExecutable, platformCodexCandidates())
}

func resolveCodexBin(configured string, lookPath executableLookup, platformCandidates []string) (string, error) {
	candidates := append([]string{strings.TrimSpace(configured), "codex"}, platformCandidates...)
	seen := map[string]struct{}{}
	var compatibilityErr error
	for _, candidate := range candidates {
		candidate = strings.TrimSpace(candidate)
		if candidate == "" {
			continue
		}
		if _, exists := seen[candidate]; exists {
			continue
		}
		seen[candidate] = struct{}{}

		resolved, err := lookPath(candidate)
		if err != nil {
			if compatibilityErr == nil && errors.Is(err, appserver.ErrIndependentWriterCapabilityUnavailable) {
				compatibilityErr = err
			}
			continue
		}
		if strings.TrimSpace(resolved) == "" {
			continue
		}
		absolute, err := filepath.Abs(resolved)
		if err != nil {
			continue
		}
		return filepath.Clean(absolute), nil
	}
	if compatibilityErr != nil {
		return "", compatibilityErr
	}
	return "", fmt.Errorf("配置路径、PATH 和桌面 App 中都没有可执行的 Codex CLI")
}

func platformCodexCandidates() []string {
	if runtime.GOOS != "darwin" {
		if runtime.GOOS != "windows" {
			return nil
		}
		candidates := []string{}
		if localAppData := strings.TrimSpace(os.Getenv("LOCALAPPDATA")); localAppData != "" {
			candidates = append(candidates,
				filepath.Join(localAppData, "Microsoft", "WindowsApps", "codex.exe"),
				filepath.Join(localAppData, "Programs", "Codex", "codex.exe"),
				filepath.Join(localAppData, "Codex", "codex.exe"))
		}
		if appData := strings.TrimSpace(os.Getenv("APPDATA")); appData != "" {
			candidates = append(candidates,
				filepath.Join(appData, "npm", "codex.cmd"),
				filepath.Join(appData, "npm", "codex.exe"),
				filepath.Join(appData, "Codex", "codex.exe"))
		}
		return candidates
	}
	candidates := []string{
		"/Applications/ChatGPT.app/Contents/Resources/codex",
		"/Applications/Codex.app/Contents/Resources/codex",
	}
	if home, err := os.UserHomeDir(); err == nil {
		candidates = append(candidates,
			filepath.Join(home, "Applications/ChatGPT.app/Contents/Resources/codex"),
			filepath.Join(home, "Applications/Codex.app/Contents/Resources/codex"),
		)
	}
	return candidates
}

// RepairCodexBin 只更新 codex.bin，并保留 auth、projects 及未来新增字段。
// 写入复用私有文件的原子替换逻辑，避免修复中断后留下半份配置或放宽权限。
func RepairCodexBin(configPath string) (string, bool, error) {
	return repairCodexBin(configPath, ResolveCodexBin, nil)
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
	document := map[string]json.RawMessage{}
	if err := json.Unmarshal(original, &document); err != nil {
		return "", false, fmt.Errorf("解析配置文件失败：%w", err)
	}
	if document == nil {
		return "", false, fmt.Errorf("配置文件必须是 JSON object")
	}

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

	resolved, err := resolve(configured)
	if err != nil {
		return "", false, err
	}
	if resolved == configured {
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
		// codex.bin 是 stable-owner 身份的一部分。先取得 daemon operation
		// lock，再以同一 raw snapshot CAS 提交。auto owner 可由新 agentd
		// 按新路径重建；manual pending 必须保留，Doctor 不能替用户确认迁移。
		// 当前 daemon 不会被停止，原生 Codex 流程不受影响。
		commitCtx, cancelCommit := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancelCommit()
		writeErr = commitConfigRepairingOwnedSharedDaemonIdentity(
			commitCtx,
			cfgPath,
			validateOriginal,
			func() error {
				return writePrivateFileAtomicallyCAS(cfgPath, original, updated)
			},
		)
	} else {
		writeErr = writeConfig(cfgPath, updated)
	}
	if writeErr != nil {
		return "", false, fmt.Errorf("原子更新配置文件失败：%w", writeErr)
	}
	return resolved, true, nil
}
