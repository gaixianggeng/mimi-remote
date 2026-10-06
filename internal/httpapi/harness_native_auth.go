package httpapi

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
	agentsetup "github.com/gaixianggeng/mimi-remote/internal/setup"
)

const (
	// deepSeekCredentialRenewalCooldown 限制失败后的重新发现频率：每次发现都要执行
	// launchctl 并读取 Harness 日志，移动端轮询不能把它放大成高频探测。
	deepSeekCredentialRenewalCooldown = 30 * time.Second
	// deepSeekCredentialRenewalTimeout 是单次重新发现的上限，含 launchctl 与一次握手。
	deepSeekCredentialRenewalTimeout = 5 * time.Second
)

var (
	errDeepSeekBaseURLUnavailable     = errors.New("deepseek.base_url 不可用")
	errDeepSeekCredentialsUnavailable = errors.New("读取 Harness 凭据失败")
	errDeepSeekRenewalUnavailable     = errors.New("没有可自动更新凭据的 DeepSeek 配置")
)

// deepSeekCredentialRenewal 串行化“已存 token 被拒 → 重新发现”的恢复（#587）。
//
// Harness 每次进程启动都会换启动 token。被拒时只让一个请求执行重新发现，并发请求
// 等它结束后直接重读 token 文件；失败后冷却一段时间，避免每个 401 都触发一次发现。
type deepSeekCredentialRenewal struct {
	once sync.Once
	gate chan struct{}
	// failedAt 只在持有 gate 时读写。
	failedAt time.Time
	// renew 是测试接缝；为 nil 时调用 setup.RotateDeepSeekCredential。
	renew func(context.Context) error
}

func (d *deepSeekCredentialRenewal) acquire(ctx context.Context) bool {
	d.once.Do(func() { d.gate = make(chan struct{}, 1) })
	select {
	case d.gate <- struct{}{}:
		return true
	case <-ctx.Done():
		return false
	}
}

func (d *deepSeekCredentialRenewal) release() { <-d.gate }

// authenticatedDeepSeekClient 用已存启动 token 完成 Harness 认证。
//
// Harness 拒绝 token 时（通常是它重启过），先为受管连接换上同一地址上的新凭据，再试一次。
// 返回的错误可用 errors.Is 区分：地址不可用、凭据读不到、凭据被拒，其余按服务不可达处理。
func (r *Router) authenticatedDeepSeekClient(ctx context.Context) (*harnessclient.Client, error) {
	for renewed := false; ; renewed = true {
		token, err := readDeepSeekTokenFile(r.cfg.DeepSeek.TokenFile)
		if err != nil {
			return nil, err
		}
		baseURL, err := config.NormalizeDeepSeekBaseURL(r.cfg.DeepSeek.BaseURL)
		if err != nil || baseURL == "" {
			return nil, errDeepSeekBaseURLUnavailable
		}
		client, err := harnessclient.New(harnessclient.Config{BaseURL: baseURL, AccessToken: token})
		if err != nil {
			return nil, errDeepSeekBaseURLUnavailable
		}
		err = client.Authenticate(ctx)
		if err == nil {
			return client, nil
		}
		if renewed || !errors.Is(err, harnessclient.ErrCredentialsRejected) ||
			!r.renewRejectedDeepSeekCredential(ctx, token) {
			return nil, err
		}
	}
}

// readDeepSeekTokenFile 只读 regular file：凭据误指向命名管道时，读取不受 context 超时控制。
func readDeepSeekTokenFile(path string) (string, error) {
	info, err := os.Stat(path)
	if err != nil {
		return "", fmt.Errorf("%w：%v", errDeepSeekCredentialsUnavailable, err)
	}
	if !info.Mode().IsRegular() {
		return "", fmt.Errorf("%w：不是普通文件", errDeepSeekCredentialsUnavailable)
	}
	token, err := harnessclient.ReadTokenFile(path)
	if err != nil {
		return "", fmt.Errorf("%w：%v", errDeepSeekCredentialsUnavailable, err)
	}
	return token, nil
}

// renewRejectedDeepSeekCredential 在 Harness 拒绝 rejected 后尝试换上新凭据。
// 返回 true 表示 token 文件里已是值得重试一次的凭据：本次换上的，或并发请求刚换过的。
func (r *Router) renewRejectedDeepSeekCredential(ctx context.Context, rejected string) bool {
	renewal := &r.deepSeekCredential
	if !renewal.acquire(ctx) {
		return false
	}
	defer renewal.release()
	if current, err := readDeepSeekTokenFile(r.cfg.DeepSeek.TokenFile); err == nil && current != rejected {
		return true
	}
	if !renewal.failedAt.IsZero() && time.Since(renewal.failedAt) < deepSeekCredentialRenewalCooldown {
		return false
	}
	renewCtx, cancel := context.WithTimeout(ctx, deepSeekCredentialRenewalTimeout)
	defer cancel()
	if err := r.renewDeepSeekCredential(renewCtx); err != nil {
		renewal.failedAt = time.Now()
		log.Printf("DeepSeek 启动凭据未能自动更新 err=%s", sanitizeGatewayDiagnostic(err.Error()))
		return false
	}
	renewal.failedAt = time.Time{}
	log.Printf("DeepSeek 启动凭据已随 Harness 重启自动更新")
	return true
}

func (r *Router) renewDeepSeekCredential(ctx context.Context) error {
	if r.deepSeekCredential.renew != nil {
		return r.deepSeekCredential.renew(ctx)
	}
	// 没有配置路径时（例如测试直接构造的 Router）不能回落到默认配置文件。
	if strings.TrimSpace(r.configPath) == "" {
		return errDeepSeekRenewalUnavailable
	}
	return agentsetup.RotateDeepSeekCredential(ctx, r.configPath, r.cfg.DeepSeek.BaseURL)
}
