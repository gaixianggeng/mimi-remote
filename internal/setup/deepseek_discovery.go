package setup

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/url"
	"strconv"
	"strings"
	"unicode"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
)

const (
	maxDeepSeekStartupURLBytes = 16 << 10
	// harnessclient.ReadTokenFile 接受的文件最大 4 KiB；落盘时还会追加一个换行。
	maxDeepSeekTokenBytes = (4 << 10) - 1
)

var errDeepSeekNotDiscovered = errors.New("未发现当前用户正在运行的 DeepSeek Harness 后台服务")

type deepSeekConnectionCandidate struct {
	BaseURL string
	Token   string
	PID     int
}

type deepSeekRuntimeDependencies struct {
	discover   func(context.Context) (deepSeekConnectionCandidate, error)
	currentPID func(context.Context) (int, error)
	probe      func(context.Context, deepSeekConnectionCandidate) error
}

func defaultDeepSeekRuntimeDependencies() deepSeekRuntimeDependencies {
	return deepSeekRuntimeDependencies{
		discover:   discoverDeepSeekLaunchAgent,
		currentPID: currentDeepSeekLaunchAgentPID,
		probe:      probeDeepSeekCandidate,
	}
}

func parseDeepSeekStartupURL(raw string) (deepSeekConnectionCandidate, error) {
	value := strings.TrimSpace(raw)
	if value == "" {
		return deepSeekConnectionCandidate{}, errors.New("Harness 启动链接不能为空")
	}
	if len(value) > maxDeepSeekStartupURLBytes {
		return deepSeekConnectionCandidate{}, fmt.Errorf("Harness 启动链接不能超过 %d 字节", maxDeepSeekStartupURLBytes)
	}
	parsed, err := url.Parse(value)
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		return deepSeekConnectionCandidate{}, errors.New("Harness 启动链接不是完整 URL")
	}
	if parsed.User != nil || parsed.Fragment != "" {
		return deepSeekConnectionCandidate{}, errors.New("Harness 启动链接不能包含用户信息或片段")
	}
	values, err := url.ParseQuery(parsed.RawQuery)
	if err != nil {
		return deepSeekConnectionCandidate{}, errors.New("Harness 启动链接查询参数无效")
	}
	tokens, ok := values["token"]
	if !ok || len(tokens) != 1 || strings.TrimSpace(tokens[0]) == "" {
		return deepSeekConnectionCandidate{}, errors.New("Harness 启动链接必须包含唯一的 token")
	}
	token := strings.TrimSpace(tokens[0])
	if len(token) > maxDeepSeekTokenBytes {
		return deepSeekConnectionCandidate{}, errors.New("Harness 启动链接的 token 过长")
	}
	if strings.IndexFunc(token, unicode.IsControl) >= 0 {
		return deepSeekConnectionCandidate{}, errors.New("Harness 启动链接的 token 包含控制字符")
	}
	if len(values) != 1 {
		return deepSeekConnectionCandidate{}, errors.New("Harness 启动链接包含不支持的查询参数")
	}
	parsed.RawQuery = ""
	baseURL, err := config.NormalizeDeepSeekBaseURL(parsed.String())
	if err != nil {
		return deepSeekConnectionCandidate{}, errors.New("Harness 启动链接的服务地址无效")
	}
	if baseURL == "" {
		return deepSeekConnectionCandidate{}, errors.New("Harness 启动链接缺少服务地址")
	}
	return deepSeekConnectionCandidate{BaseURL: baseURL, Token: token}, nil
}

func validateDiscoveredDeepSeekCandidate(candidate deepSeekConnectionCandidate) error {
	parsed, err := url.Parse(candidate.BaseURL)
	if err != nil || parsed.Scheme != "http" || parsed.Hostname() != "127.0.0.1" {
		return errors.New("自动发现的 Harness 地址必须使用 127.0.0.1 明文回环地址")
	}
	port, err := strconv.Atoi(parsed.Port())
	if err != nil || port < 1 || port > 65535 {
		return errors.New("自动发现的 Harness 端口无效")
	}
	if parsed.Path != "" && parsed.Path != "/" {
		return errors.New("自动发现的 Harness 地址不能包含路径")
	}
	if net.ParseIP(parsed.Hostname()) == nil || strings.TrimSpace(candidate.Token) == "" || candidate.PID <= 0 {
		return errors.New("自动发现的 Harness 启动信息不完整")
	}
	return nil
}

func probeDeepSeekCandidate(ctx context.Context, candidate deepSeekConnectionCandidate) error {
	client, err := harnessclient.New(harnessclient.Config{
		BaseURL:     candidate.BaseURL,
		AccessToken: candidate.Token,
	})
	if err != nil {
		return err
	}
	if err := client.Authenticate(ctx); err != nil {
		return err
	}
	catalog, err := client.ModelCatalog(ctx)
	if err != nil {
		return err
	}
	for _, group := range catalog.Groups {
		if len(group.Models) > 0 {
			return nil
		}
	}
	return errors.New("Harness 模型目录没有可用模型")
}
