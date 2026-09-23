// Package hostinfo 读取当前宿主设备的用户可识别名称。
//
// 设备名只用于客户端展示默认名（未自定义名字的连接）。它不是身份字段：
// installation_id 仍是唯一的跨设备身份边界，改名不会合并或新建连接档案。
package hostinfo

import (
	"context"
	"os"
	"strings"
	"sync"
	"time"
	"unicode"
)

const (
	// 宿主系统允许的电脑名上限是 63 个字符；超长名称截断后再交给客户端，
	// 避免客户端因长度校验整条丢弃而退回地址。
	maxDeviceNameRunes = 63
	// 读取系统电脑名最多等待 2 秒，不能让展示字段拖慢 /api/version。
	commandTimeout = 2 * time.Second
	// scutil 正常输出远小于该上限；异常巨量输出直接视为不可用。
	commandOutputLimit = 4 * 1024
	// mDNS 后缀属于路由信息，不属于设备名本身。
	localSuffix = ".local"
)

// Discover 读取宿主设备名：优先系统「电脑名称」，取不到时退回主机名。
// 两者都不可用时返回空字符串，调用方必须保持原有回退，不得用占位名伪造设备名。
func Discover(ctx context.Context) string {
	return discover(ctx, platformComputerName, os.Hostname)
}

func discover(
	ctx context.Context,
	computerName func(context.Context) string,
	hostname func() (string, error),
) string {
	if name := normalizeDeviceName(computerName(ctx)); name != "" {
		return name
	}
	raw, err := hostname()
	if err != nil {
		return ""
	}
	return normalizeDeviceName(raw)
}

// normalizeDeviceName 统一裁剪系统返回值：去掉首尾空白、末尾点号和 `.local` 后缀，
// 拒绝含控制字符的异常输出，并把超长名称截断到系统允许的长度。
func normalizeDeviceName(raw string) string {
	value := strings.TrimSuffix(strings.TrimSpace(raw), ".")
	if len(value) > len(localSuffix) &&
		strings.EqualFold(value[len(value)-len(localSuffix):], localSuffix) {
		value = value[:len(value)-len(localSuffix)]
	}
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}
	for _, char := range value {
		if unicode.IsControl(char) {
			return ""
		}
	}
	runes := []rune(value)
	if len(runes) > maxDeviceNameRunes {
		runes = runes[:maxDeviceNameRunes]
	}
	return string(runes)
}

// Resolver 对设备名做短缓存，让 /api/version 只读内存就能返回展示名。
//
// 构造时立即预热；缓存过期后的读取先返回旧值，再在后台重新解析。宿主改名最多
// 在一个 TTL 之后生效，而任何一次请求都不会被系统调用或子进程拖慢。
type Resolver struct {
	mu         sync.Mutex
	ttl        time.Duration
	lookup     func(context.Context) string
	cached     string
	expiresAt  time.Time
	resolved   bool
	refreshing bool
}

func NewResolver(ttl time.Duration) *Resolver {
	resolver := newResolver(ttl, Discover)
	resolver.refresh()
	return resolver
}

func newResolver(ttl time.Duration, lookup func(context.Context) string) *Resolver {
	if ttl <= 0 {
		ttl = time.Minute
	}
	return &Resolver{ttl: ttl, lookup: lookup}
}

func (r *Resolver) Lookup(ctx context.Context) string {
	if r == nil {
		return ""
	}
	r.mu.Lock()
	if !r.resolved {
		// 预热尚未完成时的兜底：同步解析一次，不让客户端长期拿不到设备名。
		value := r.lookup(ctx)
		r.store(value)
		r.mu.Unlock()
		return value
	}
	cached := r.cached
	stale := !time.Now().Before(r.expiresAt)
	r.mu.Unlock()
	if stale {
		r.refresh()
	}
	return cached
}

// refresh 在后台重新解析设备名。同一时刻最多只有一个解析在跑，
// 因此过期缓存被高频访问时也不会放大系统调用。
func (r *Resolver) refresh() {
	if r == nil {
		return
	}
	r.mu.Lock()
	if r.refreshing {
		r.mu.Unlock()
		return
	}
	r.refreshing = true
	r.mu.Unlock()
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), commandTimeout)
		defer cancel()
		value := r.lookup(ctx)
		r.mu.Lock()
		r.store(value)
		r.mu.Unlock()
	}()
}

// store 记录一次解析结果，调用方必须已持有 r.mu。空值同样进入缓存，
// 避免系统名不可用时每次请求都重试子进程。
func (r *Resolver) store(value string) {
	r.cached = value
	r.expiresAt = time.Now().Add(r.ttl)
	r.resolved = true
	r.refreshing = false
}
