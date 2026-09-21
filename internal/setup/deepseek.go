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

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
)

type DeepSeekRuntimeAction string

const (
	DeepSeekRuntimeInspect  DeepSeekRuntimeAction = "inspect"
	DeepSeekRuntimeConnect  DeepSeekRuntimeAction = "connect"
	DeepSeekRuntimeDisabled DeepSeekRuntimeAction = "disabled"
	DeepSeekRuntimeRefresh  DeepSeekRuntimeAction = "refresh"
)

const managedDeepSeekTokenFilename = "deepseek.token"

// DeepSeekConfigurationResult 是 Mac App 可安全展示的配置结果。
// 凭据和含凭据的启动链接禁止加入该结构。
type DeepSeekConfigurationResult struct {
	Enabled         bool   `json:"enabled"`
	Available       bool   `json:"available"`
	Discovered      bool   `json:"discovered"`
	BaseURL         string `json:"base_url"`
	Message         string `json:"message"`
	RestartRequired bool   `json:"restart_required"`
}

type deepSeekConfigDocument struct {
	root         map[string]json.RawMessage
	deepSeek     map[string]json.RawMessage
	original     []byte
	configPath   string
	enabled      bool
	baseURL      string
	tokenFile    string
	autoDiscover bool
}

func ParseDeepSeekRuntimeAction(raw string) (DeepSeekRuntimeAction, error) {
	action := DeepSeekRuntimeAction(strings.ToLower(strings.TrimSpace(raw)))
	switch action {
	case DeepSeekRuntimeInspect, DeepSeekRuntimeConnect, DeepSeekRuntimeDisabled, DeepSeekRuntimeRefresh:
		return action, nil
	default:
		return "", errors.New("DeepSeek 操作只支持 inspect、connect、disabled 或 refresh")
	}
}

// ConfigureDeepSeek 发现并验证用户已经启动的 Harness 服务，只管理 agentd 的连接配置。
// 它不会安装、启动、停止或改写 Harness。
func ConfigureDeepSeek(
	ctx context.Context,
	configPath string,
	action DeepSeekRuntimeAction,
	startupURL string,
) (DeepSeekConfigurationResult, error) {
	return configureDeepSeek(ctx, configPath, action, startupURL, defaultDeepSeekRuntimeDependencies())
}

func configureDeepSeek(
	ctx context.Context,
	configPath string,
	action DeepSeekRuntimeAction,
	startupURL string,
	dependencies deepSeekRuntimeDependencies,
) (DeepSeekConfigurationResult, error) {
	action, err := ParseDeepSeekRuntimeAction(string(action))
	if err != nil {
		return DeepSeekConfigurationResult{}, err
	}
	document, err := loadDeepSeekConfigDocument(configPath)
	if err != nil {
		return DeepSeekConfigurationResult{}, err
	}
	result := DeepSeekConfigurationResult{
		Enabled: document.enabled,
		BaseURL: document.baseURL,
	}

	switch action {
	case DeepSeekRuntimeDisabled:
		if strings.TrimSpace(startupURL) != "" {
			return DeepSeekConfigurationResult{}, errors.New("disabled 不接受 Harness 启动链接")
		}
		return disableDeepSeek(document, result)
	case DeepSeekRuntimeInspect:
		if strings.TrimSpace(startupURL) != "" {
			return DeepSeekConfigurationResult{}, errors.New("inspect 不接受 Harness 启动链接")
		}
		return inspectDeepSeek(ctx, document, result, dependencies), nil
	case DeepSeekRuntimeConnect:
		return connectDeepSeek(ctx, document, result, startupURL, dependencies)
	case DeepSeekRuntimeRefresh:
		if strings.TrimSpace(startupURL) != "" {
			return DeepSeekConfigurationResult{}, errors.New("refresh 不接受 Harness 启动链接")
		}
		return refreshDeepSeek(ctx, document, result, dependencies)
	default:
		return DeepSeekConfigurationResult{}, errors.New("不支持的 DeepSeek 操作")
	}
}

func inspectDeepSeek(
	ctx context.Context,
	document deepSeekConfigDocument,
	result DeepSeekConfigurationResult,
	dependencies deepSeekRuntimeDependencies,
) DeepSeekConfigurationResult {
	if document.enabled {
		configured, readErr := configuredDeepSeekCandidate(document)
		if readErr == nil {
			result.Available = dependencies.probe(ctx, configured) == nil
		}
		if result.Available {
			result.Message = "当前 DeepSeek Harness 连接可用。"
		} else {
			result.Message = "DeepSeek 已启用，但当前连接不可用。"
		}
		return result
	}
	candidate, discovered, err := findDeepSeekCandidate(ctx, "", dependencies)
	if err == nil {
		result.Discovered = discovered
		result.Available = probeAndRecheckDeepSeek(ctx, candidate, discovered, dependencies) == nil
		result.BaseURL = candidate.BaseURL
		if result.Available {
			result.Message = "已发现可连接的 DeepSeek Harness 服务。"
		} else {
			result.Message = "已发现 DeepSeek Harness 服务，但认证或模型目录检查失败。"
		}
		return result
	}

	result.Message = "未发现当前用户正在运行的 DeepSeek Harness 后台服务。"
	return result
}

func connectDeepSeek(
	ctx context.Context,
	document deepSeekConfigDocument,
	result DeepSeekConfigurationResult,
	startupURL string,
	dependencies deepSeekRuntimeDependencies,
) (DeepSeekConfigurationResult, error) {
	if strings.TrimSpace(startupURL) == "" {
		if configured, configuredErr := configuredDeepSeekCandidate(document); configuredErr == nil {
			result.BaseURL = configured.BaseURL
			result.Available = dependencies.probe(ctx, configured) == nil
			return enableConfiguredDeepSeek(document, result)
		}
	}

	candidate, discovered, err := findDeepSeekCandidate(ctx, startupURL, dependencies)
	if err != nil {
		result.Message = "未找到可连接的 DeepSeek Harness 服务。"
		return result, nil
	}
	result.Discovered = discovered
	if err := probeAndRecheckDeepSeek(ctx, candidate, discovered, dependencies); err != nil {
		result.Message = "DeepSeek Harness 认证或模型目录检查失败；配置未更改。"
		return result, nil
	}
	result.Available = true
	result.BaseURL = candidate.BaseURL
	changed, err := storeDeepSeekConnection(ctx, document, candidate, true, discovered)
	if err != nil {
		return DeepSeekConfigurationResult{}, err
	}
	result.Enabled = true
	result.RestartRequired = changed
	result.Message = "DeepSeek Harness 已验证并保存。"
	return result, nil
}

// 重新开启既有连接时只修改用户启用状态。Harness 当前离线不应让开关回落，
// 也不能为了重试而改写已保存的地址、凭据或自动发现偏好。
func enableConfiguredDeepSeek(
	document deepSeekConfigDocument,
	result DeepSeekConfigurationResult,
) (DeepSeekConfigurationResult, error) {
	updated, err := encodeDeepSeekEnabled(document, true)
	if err != nil {
		return DeepSeekConfigurationResult{}, err
	}
	if err := writePrivateFileAtomicallyCAS(document.configPath, document.original, updated); err != nil {
		return DeepSeekConfigurationResult{}, fmt.Errorf("更新 DeepSeek 配置失败：%w", err)
	}
	result.Enabled = true
	result.RestartRequired = !bytes.Equal(updated, document.original)
	if result.Available {
		result.Message = "DeepSeek Harness 已启用，当前连接可用。"
	} else {
		result.Message = "DeepSeek Harness 已启用，但当前连接不可用；配置已保留。"
	}
	return result, nil
}

func refreshDeepSeek(
	ctx context.Context,
	document deepSeekConfigDocument,
	result DeepSeekConfigurationResult,
	dependencies deepSeekRuntimeDependencies,
) (DeepSeekConfigurationResult, error) {
	if !document.enabled {
		// 检测到服务不代表用户同意启用。关闭状态只检查，不落盘。
		return inspectDeepSeek(ctx, document, result, dependencies), nil
	}
	managedTokenPath := managedDeepSeekTokenPath(document.configPath)
	if !document.autoDiscover || filepath.Clean(document.tokenFile) != managedTokenPath {
		result.Message = "当前 DeepSeek 连接未启用受管自动发现，未自动替换服务。"
		configured, err := configuredDeepSeekCandidate(document)
		if err == nil {
			result.Available = dependencies.probe(ctx, configured) == nil
		}
		return result, nil
	}
	candidate, discovered, err := findDeepSeekCandidate(ctx, "", dependencies)
	if err != nil {
		result.Message = "未发现正在运行的 DeepSeek Harness；保留现有配置。"
		return result, nil
	}
	result.Discovered = discovered
	if err := probeAndRecheckDeepSeek(ctx, candidate, discovered, dependencies); err != nil {
		result.Message = "DeepSeek Harness 认证或模型目录检查失败；保留现有配置。"
		return result, nil
	}
	result.Available = true
	result.BaseURL = candidate.BaseURL
	changed, err := storeDeepSeekConnection(ctx, document, candidate, true, true)
	if err != nil {
		return DeepSeekConfigurationResult{}, err
	}
	result.RestartRequired = changed
	result.Message = "DeepSeek Harness 连接已刷新。"
	return result, nil
}

func disableDeepSeek(
	document deepSeekConfigDocument,
	result DeepSeekConfigurationResult,
) (DeepSeekConfigurationResult, error) {
	if !document.enabled {
		result.Message = "DeepSeek 通道已经关闭。"
		return result, nil
	}
	updated, err := encodeDeepSeekEnabled(document, false)
	if err != nil {
		return DeepSeekConfigurationResult{}, err
	}
	if err := writePrivateFileAtomicallyCAS(document.configPath, document.original, updated); err != nil {
		return DeepSeekConfigurationResult{}, fmt.Errorf("更新 DeepSeek 配置失败：%w", err)
	}
	result.Enabled = false
	result.RestartRequired = true
	result.Message = "DeepSeek 通道已关闭。"
	return result, nil
}

func findDeepSeekCandidate(
	ctx context.Context,
	startupURL string,
	dependencies deepSeekRuntimeDependencies,
) (deepSeekConnectionCandidate, bool, error) {
	if strings.TrimSpace(startupURL) != "" {
		candidate, err := parseDeepSeekStartupURL(startupURL)
		return candidate, false, err
	}
	candidate, err := dependencies.discover(ctx)
	return candidate, err == nil, err
}

func probeAndRecheckDeepSeek(
	ctx context.Context,
	candidate deepSeekConnectionCandidate,
	discovered bool,
	dependencies deepSeekRuntimeDependencies,
) error {
	if err := dependencies.probe(ctx, candidate); err != nil {
		return err
	}
	if !discovered {
		return nil
	}
	pid, err := dependencies.currentPID(ctx)
	if err != nil || pid != candidate.PID {
		return errors.New("Harness 进程在验证期间发生变化")
	}
	return nil
}

func configuredDeepSeekCandidate(document deepSeekConfigDocument) (deepSeekConnectionCandidate, error) {
	if strings.TrimSpace(document.baseURL) == "" || strings.TrimSpace(document.tokenFile) == "" {
		return deepSeekConnectionCandidate{}, errors.New("DeepSeek 连接配置不完整")
	}
	token, err := readDeepSeekTokenFile(document.tokenFile, false)
	if err != nil {
		return deepSeekConnectionCandidate{}, errors.New("无法读取 DeepSeek 凭据")
	}
	return deepSeekConnectionCandidate{BaseURL: document.baseURL, Token: token}, nil
}

func storeDeepSeekConnection(
	ctx context.Context,
	document deepSeekConfigDocument,
	candidate deepSeekConnectionCandidate,
	enabled bool,
	autoDiscover bool,
) (bool, error) {
	tokenPath := managedDeepSeekTokenPath(document.configPath)
	updated, err := encodeDeepSeekConfig(document, enabled, candidate.BaseURL, tokenPath, autoDiscover)
	if err != nil {
		return false, err
	}
	tokenRaw := []byte(candidate.Token + "\n")
	if bytes.Equal(updated, document.original) {
		current, readErr := readDeepSeekTokenFile(tokenPath, true)
		if readErr == nil && current == candidate.Token {
			return false, nil
		}
	}

	err = withConfigCommitLock(ctx, document.configPath, func() error {
		current, readErr := os.ReadFile(document.configPath)
		if readErr != nil {
			return fmt.Errorf("重新读取配置失败：%w", readErr)
		}
		if !bytes.Equal(current, document.original) {
			return errors.New("配置已被其他进程修改，请重新执行")
		}
		return writeSetupFilesAtomically(
			document.configPath,
			tokenPath,
			updated,
			tokenRaw,
			defaultSetupFileTransactionOps(),
		)
	})
	if err != nil {
		return false, fmt.Errorf("保存 DeepSeek 连接失败：%w", err)
	}
	return true, nil
}

func readDeepSeekTokenFile(path string, requireManagedMode bool) (string, error) {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() {
		return "", errors.New("DeepSeek token 文件必须是 regular file")
	}
	if requireManagedMode && runtime.GOOS != "windows" && info.Mode().Perm() != 0o600 {
		return "", errors.New("受管 DeepSeek token 文件必须是 0600")
	}
	return harnessclient.ReadTokenFile(path)
}

func managedDeepSeekTokenPath(configPath string) string {
	return filepath.Join(filepath.Dir(configPath), managedDeepSeekTokenFilename)
}

func loadDeepSeekConfigDocument(path string) (deepSeekConfigDocument, error) {
	configPath, err := resolveConfigPath(path)
	if err != nil {
		return deepSeekConfigDocument{}, err
	}
	info, err := os.Lstat(configPath)
	if err != nil {
		return deepSeekConfigDocument{}, fmt.Errorf("读取配置文件状态失败：%w", err)
	}
	if !info.Mode().IsRegular() {
		return deepSeekConfigDocument{}, errors.New("配置文件必须是 regular file，不能是目录或符号链接")
	}
	original, err := os.ReadFile(configPath)
	if err != nil {
		return deepSeekConfigDocument{}, fmt.Errorf("读取配置文件失败：%w", err)
	}
	root := map[string]json.RawMessage{}
	if err := json.Unmarshal(original, &root); err != nil || root == nil {
		return deepSeekConfigDocument{}, errors.New("配置文件必须是 JSON object")
	}
	deepSeek := map[string]json.RawMessage{}
	if raw, ok := root["deepseek"]; ok && !bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		if err := json.Unmarshal(raw, &deepSeek); err != nil || deepSeek == nil {
			return deepSeekConfigDocument{}, errors.New("deepseek 配置必须是 JSON object")
		}
	}
	document := deepSeekConfigDocument{
		root:       root,
		deepSeek:   deepSeek,
		original:   original,
		configPath: configPath,
	}
	if err := decodeOptionalDeepSeekField(deepSeek, "enabled", &document.enabled); err != nil {
		return deepSeekConfigDocument{}, err
	}
	if err := decodeOptionalDeepSeekField(deepSeek, "base_url", &document.baseURL); err != nil {
		return deepSeekConfigDocument{}, err
	}
	normalizedBaseURL, err := config.NormalizeDeepSeekBaseURL(document.baseURL)
	if err != nil {
		return deepSeekConfigDocument{}, errors.New("deepseek.base_url 无效")
	}
	document.baseURL = normalizedBaseURL
	if err := decodeOptionalDeepSeekField(deepSeek, "token_file", &document.tokenFile); err != nil {
		return deepSeekConfigDocument{}, err
	}
	if err := decodeOptionalDeepSeekField(deepSeek, "auto_discover", &document.autoDiscover); err != nil {
		return deepSeekConfigDocument{}, err
	}
	return document, nil
}

func decodeOptionalDeepSeekField(document map[string]json.RawMessage, name string, target any) error {
	raw, ok := document[name]
	if !ok {
		return nil
	}
	if err := json.Unmarshal(raw, target); err != nil {
		return fmt.Errorf("deepseek.%s 类型无效", name)
	}
	return nil
}

func encodeDeepSeekConfig(
	document deepSeekConfigDocument,
	enabled bool,
	baseURL string,
	tokenFile string,
	autoDiscover bool,
) ([]byte, error) {
	set := func(name string, value any) error {
		raw, err := json.Marshal(value)
		if err != nil {
			return err
		}
		document.deepSeek[name] = raw
		return nil
	}
	if err := set("enabled", enabled); err != nil {
		return nil, err
	}
	if err := set("auto_discover", autoDiscover); err != nil {
		return nil, err
	}
	if strings.TrimSpace(baseURL) != "" {
		if err := set("base_url", baseURL); err != nil {
			return nil, err
		}
	}
	if strings.TrimSpace(tokenFile) != "" {
		if err := set("token_file", tokenFile); err != nil {
			return nil, err
		}
	}
	rawDeepSeek, err := json.Marshal(document.deepSeek)
	if err != nil {
		return nil, fmt.Errorf("编码 deepseek 配置失败：%w", err)
	}
	document.root["deepseek"] = rawDeepSeek
	updated, err := json.MarshalIndent(document.root, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("编码配置文件失败：%w", err)
	}
	return append(updated, '\n'), nil
}

func encodeDeepSeekEnabled(document deepSeekConfigDocument, enabled bool) ([]byte, error) {
	rawEnabled, err := json.Marshal(enabled)
	if err != nil {
		return nil, err
	}
	document.deepSeek["enabled"] = rawEnabled
	rawDeepSeek, err := json.Marshal(document.deepSeek)
	if err != nil {
		return nil, fmt.Errorf("编码 deepseek 配置失败：%w", err)
	}
	document.root["deepseek"] = rawDeepSeek
	updated, err := json.MarshalIndent(document.root, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("编码配置文件失败：%w", err)
	}
	return append(updated, '\n'), nil
}
