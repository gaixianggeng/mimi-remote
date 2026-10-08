//go:build darwin

package appserver

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

const modelDiscoveryFeature = "api_key_model_discovery"

func sharedLocalAppServerArgs(ctx context.Context, bin string, env map[string]string, listen string) ([]string, error) {
	args := []string{"-c", "features.code_mode_host=true"}
	enabled, err := configuredModelDiscovery(ctx, bin, env)
	if err != nil {
		return nil, err
	}
	if enabled != nil {
		// Desktop 会同步自己的功能发布策略到共享后台。显式参数保护 CLI 的实际值，
		// 既防止默认 true 被覆盖，也保留用户主动选择的 false；不改用户配置文件。
		args = append(args, "-c", "features."+modelDiscoveryFeature+"="+strconv.FormatBool(*enabled))
	}
	return append(args, "app-server", "--listen", listen), nil
}

func configuredModelDiscovery(ctx context.Context, bin string, env map[string]string) (*bool, error) {
	directory, err := sharedLocalWorkingDirectory(env)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, "features", "list")
	cmd.Dir = directory
	cmd.Env = buildManagedEnv(env)
	output, err := cmd.Output()
	if err != nil {
		return nil, errors.New("无法读取 Codex 功能设置，请检查 Codex 配置后重试。")
	}
	return parseConfiguredModelDiscovery(string(output))
}

func parseConfiguredModelDiscovery(output string) (*bool, error) {
	for _, line := range strings.Split(output, "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 || fields[0] != modelDiscoveryFeature {
			continue
		}
		if len(fields) < 3 || (fields[len(fields)-1] != "true" && fields[len(fields)-1] != "false") {
			return nil, errors.New("无法识别 Codex 模型发现设置，请运行诊断后重试。")
		}
		enabled := fields[len(fields)-1] == "true"
		return &enabled, nil
	}
	// 旧 CLI 没有该功能时不传未知参数，继续沿用已有启动方式。
	return nil, nil
}

func runningModelDiscovery(conn *websocket.Conn) (bool, error) {
	var cursor *string
	for id := 2; ; id++ {
		if err := conn.WriteJSON(map[string]any{
			"id": id, "method": "experimentalFeature/list",
			"params": map[string]any{"limit": 100, "cursor": cursor},
		}); err != nil {
			return false, err
		}
		type featurePage struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Error  *RPCError       `json:"error"`
			Result struct {
				Data []struct {
					Name    string `json:"name"`
					Enabled *bool  `json:"enabled"`
				} `json:"data"`
				NextCursor *string `json:"nextCursor"`
			} `json:"result"`
		}
		var frame featurePage
		for {
			frame = featurePage{}
			if err := conn.ReadJSON(&frame); err != nil {
				return false, err
			}
			if frame.Method == "" && string(frame.ID) == strconv.Itoa(id) {
				break
			}
		}
		if frame.Error != nil {
			return false, fmt.Errorf("读取 Codex 功能设置失败：%w", frame.Error)
		}
		if frame.Result.Data == nil {
			return false, errors.New("Codex 未返回有效的功能设置")
		}
		for _, feature := range frame.Result.Data {
			if feature.Name == modelDiscoveryFeature {
				if feature.Enabled == nil {
					return false, errors.New("Codex 未返回有效的模型发现设置")
				}
				return *feature.Enabled, nil
			}
		}
		if frame.Result.NextCursor == nil || *frame.Result.NextCursor == "" {
			// 与终端兼容检查一致，旧后台缺少该功能视为未启用。
			return false, nil
		}
		cursor = frame.Result.NextCursor
	}
}
