package hostinfo

import (
	"context"
	"errors"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestDiscoverPrefersComputerNameOverHostname(t *testing.T) {
	hostnameCalls := 0
	name := discover(
		context.Background(),
		func(context.Context) string { return "工作室的 Mac Studio\n" },
		func() (string, error) {
			hostnameCalls++
			return "studio-mac.local", nil
		},
	)
	if name != "工作室的 Mac Studio" {
		t.Fatalf("应优先使用系统电脑名：%q", name)
	}
	if hostnameCalls != 0 {
		t.Fatalf("电脑名可用时不应再读主机名，calls=%d", hostnameCalls)
	}
}

func TestDiscoverFallsBackToHostname(t *testing.T) {
	tests := []struct {
		name         string
		computerName string
		hostname     string
		hostnameErr  error
		want         string
	}{
		{name: "无电脑名时用主机名并去掉 mDNS 后缀", hostname: "Studio-Mac.local", want: "Studio-Mac"},
		{name: "主机名带末尾点号", hostname: "studio-mac.local.", want: "studio-mac"},
		{name: "主机名无后缀", hostname: "studio-mac", want: "studio-mac"},
		{name: "电脑名空白视为缺失", computerName: "   ", hostname: "studio-mac", want: "studio-mac"},
		{name: "主机名读取失败时保持空值", computerName: " ", hostnameErr: errors.New("boom"), want: ""},
		{name: "含控制字符的电脑名被拒绝", computerName: "bad\x00name", hostname: "studio-mac", want: "studio-mac"},
	}
	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			name := discover(
				context.Background(),
				func(context.Context) string { return testCase.computerName },
				func() (string, error) { return testCase.hostname, testCase.hostnameErr },
			)
			if name != testCase.want {
				t.Fatalf("设备名异常：got=%q want=%q", name, testCase.want)
			}
		})
	}
}

func TestNormalizeDeviceNameTruncatesOverlongNames(t *testing.T) {
	name := normalizeDeviceName(strings.Repeat("名", 100))
	if len([]rune(name)) != maxDeviceNameRunes {
		t.Fatalf("超长设备名应截断到 %d 个字符：%d", maxDeviceNameRunes, len([]rune(name)))
	}
}

// .local 后缀只在作为后缀出现时去掉，主机名中间的点号属于名称本身。
func TestNormalizeDeviceNameKeepsInnerDots(t *testing.T) {
	if got := normalizeDeviceName("studio.local.lan"); got != "studio.local.lan" {
		t.Fatalf("非后缀的 .local 不应被裁剪：%q", got)
	}
}

func TestResolverCachesUntilTTLExpires(t *testing.T) {
	var calls atomic.Int32
	resolver := newResolver(time.Minute, func(context.Context) string {
		if calls.Add(1) == 1 {
			return "studio-mac"
		}
		return "renamed-mac"
	})
	resolver.Lookup(context.Background())
	waitForResolver(t, resolver)
	if got := resolver.Lookup(context.Background()); got != "studio-mac" {
		t.Fatalf("首次读取异常：%q", got)
	}
	if got := resolver.Lookup(context.Background()); got != "studio-mac" {
		t.Fatalf("TTL 内应返回缓存值：%q", got)
	}
	if calls.Load() != 1 {
		t.Fatalf("TTL 内不应重复读取，calls=%d", calls.Load())
	}
}

// 空值同样进入缓存，避免不可用的系统调用被高频重试。
func TestResolverCachesEmptyResult(t *testing.T) {
	var calls atomic.Int32
	resolver := newResolver(time.Minute, func(context.Context) string {
		calls.Add(1)
		return ""
	})
	if got := resolver.Lookup(context.Background()); got != "" {
		t.Fatalf("空设备名应原样返回：%q", got)
	}
	waitForResolver(t, resolver)
	if got := resolver.Lookup(context.Background()); got != "" {
		t.Fatalf("空设备名应保持空值：%q", got)
	}
	if calls.Load() != 1 {
		t.Fatalf("空值也应缓存，calls=%d", calls.Load())
	}
}

// 过期后先返回旧值，再在后台刷新，请求路径不会被重新解析阻塞。
func TestResolverRefreshesInBackgroundAfterTTL(t *testing.T) {
	var calls atomic.Int32
	resolver := newResolver(30*time.Millisecond, func(context.Context) string {
		if calls.Add(1) == 1 {
			return "studio-mac"
		}
		return "renamed-mac"
	})
	resolver.Lookup(context.Background())
	waitForResolver(t, resolver)
	if got := resolver.Lookup(context.Background()); got != "studio-mac" {
		t.Fatalf("首次读取异常：%q", got)
	}
	time.Sleep(40 * time.Millisecond)
	if got := resolver.Lookup(context.Background()); got != "studio-mac" {
		t.Fatalf("过期缓存应先返回旧值：%q", got)
	}
	deadline := time.Now().Add(2 * time.Second)
	for resolver.Lookup(context.Background()) != "renamed-mac" {
		if time.Now().After(deadline) {
			t.Fatal("过期后未在后台刷新设备名")
		}
		time.Sleep(5 * time.Millisecond)
	}
	if calls.Load() != 2 {
		t.Fatalf("过期刷新应只解析一次，calls=%d", calls.Load())
	}
}

func TestResolverColdLookupNeverBlocksOrDuplicatesPrewarm(t *testing.T) {
	var calls atomic.Int32
	started := make(chan struct{})
	release := make(chan struct{}, 1)
	defer close(release)
	resolver := newResolver(time.Minute, func(context.Context) string {
		calls.Add(1)
		close(started)
		<-release
		return "studio-mac"
	})
	resolver.refresh()
	<-started

	result := make(chan string, 1)
	go func() { result <- resolver.Lookup(context.Background()) }()
	select {
	case got := <-result:
		if got != "" {
			t.Fatalf("预热未完成时应返回空缓存：%q", got)
		}
	case <-time.After(time.Second):
		t.Fatal("冷缓存请求被系统设备名探测阻塞")
	}
	if calls.Load() != 1 {
		t.Fatalf("冷缓存请求不应重复探测，calls=%d", calls.Load())
	}
	release <- struct{}{}
	waitForResolver(t, resolver)
	if got := resolver.Lookup(context.Background()); got != "studio-mac" {
		t.Fatalf("预热完成后应返回设备名：%q", got)
	}
}

func waitForResolver(t *testing.T, resolver *Resolver) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for {
		resolver.mu.Lock()
		resolved := resolver.resolved
		resolver.mu.Unlock()
		if resolved {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("设备名后台探测未完成")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func TestResolverLookupIsNilSafe(t *testing.T) {
	var resolver *Resolver
	if got := resolver.Lookup(context.Background()); got != "" {
		t.Fatalf("空 Resolver 应返回空值：%q", got)
	}
	resolver.refresh()
}

func TestNewResolverFallsBackToDefaultTTL(t *testing.T) {
	if got := newResolver(0, func(context.Context) string { return "" }).ttl; got != time.Minute {
		t.Fatalf("非正 TTL 应回落到默认值：%s", got)
	}
}
