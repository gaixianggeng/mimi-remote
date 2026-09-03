package managed

import (
	"errors"
	"reflect"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/experiments/tailcat/internal/tunnel"
	"tailscale.com/types/key"
)

type fakeManagedHost struct {
	address    string
	publicKey  string
	closed     bool
	closeCalls int
	closeErr   error
}

func (h *fakeManagedHost) AddAllowedClient(string) error { return nil }
func (h *fakeManagedHost) Address() string               { return h.address }
func (h *fakeManagedHost) PublicKey() string             { return h.publicKey }
func (h *fakeManagedHost) Close() error {
	h.closeCalls++
	if h.closeErr != nil {
		return h.closeErr
	}
	h.closed = true
	return nil
}

func TestReplaceManagedClientsRetainsOldHostWhenCloseFails(t *testing.T) {
	oldManagedKey := key.NewNode().Public().String()
	newManagedKey := key.NewNode().Public().String()
	oldHost := &fakeManagedHost{closeErr: errors.New("close failed")}
	startCalls := 0
	manager := &Manager{
		host:           oldHost,
		managedClients: []string{oldManagedKey},
		startHost: func(tunnel.HostConfig) (managedHost, error) {
			startCalls++
			return &fakeManagedHost{}, nil
		},
	}

	if _, err := manager.ReplaceManagedClients([]string{newManagedKey}); err == nil {
		t.Fatal("旧主机关闭失败时应中止替换")
	}
	if manager.host != oldHost || oldHost.closed || oldHost.closeCalls != 1 || startCalls != 0 {
		t.Fatalf("关闭失败后必须保留旧主机供重试：host=%v closed=%t closes=%d starts=%d", manager.host == oldHost, oldHost.closed, oldHost.closeCalls, startCalls)
	}
	if !reflect.DeepEqual(manager.managedClients, []string{oldManagedKey}) {
		t.Fatal("关闭失败不能提交新托管策略")
	}

	oldHost.closeErr = nil
	if _, err := manager.ReplaceManagedClients([]string{newManagedKey}); err != nil {
		t.Fatal(err)
	}
	if !oldHost.closed || oldHost.closeCalls != 2 || startCalls != 1 {
		t.Fatalf("下一次同步应重试关闭并完成替换：closed=%t closes=%d starts=%d", oldHost.closed, oldHost.closeCalls, startCalls)
	}
}

func TestStartPairingRetainsOldPairHostWhenCloseFails(t *testing.T) {
	oldPairHost := &fakeManagedHost{closeErr: errors.New("close failed")}
	startCalls := 0
	manager := &Manager{
		config:        Config{StateDir: t.TempDir()},
		pairHost:      oldPairHost,
		pairExpiresAt: time.Now().Add(time.Minute),
		startHost: func(tunnel.HostConfig) (managedHost, error) {
			startCalls++
			return &fakeManagedHost{}, nil
		},
	}

	if _, err := manager.StartPairing(time.Minute); err == nil {
		t.Fatal("旧配对主机关闭失败时应中止新配对")
	}
	if manager.pairHost != oldPairHost || oldPairHost.closeCalls != 1 || startCalls != 0 {
		t.Fatalf("关闭失败后必须保留旧配对主机：retained=%t closes=%d starts=%d", manager.pairHost == oldPairHost, oldPairHost.closeCalls, startCalls)
	}
}

func TestExpiredPairHostRetriesCloseFailure(t *testing.T) {
	oldPairHost := &fakeManagedHost{closeErr: errors.New("close failed")}
	manager := &Manager{
		config:         Config{StateDir: t.TempDir()},
		pairHost:       oldPairHost,
		pairExpiresAt:  time.Now().Add(-time.Second),
		pairGeneration: 7,
	}

	manager.mu.Lock()
	manager.schedulePairExpiryLocked(7, 0)
	manager.mu.Unlock()
	for range 100 {
		manager.mu.Lock()
		closeAttempted := oldPairHost.closeCalls > 0
		manager.mu.Unlock()
		if closeAttempted {
			break
		}
		time.Sleep(time.Millisecond)
	}
	manager.mu.Lock()
	retainedAfterFailure := manager.pairHost == oldPairHost && oldPairHost.closeCalls > 0
	manager.mu.Unlock()
	if !retainedAfterFailure {
		t.Fatal("过期配对主机关闭失败时应保留句柄并安排重试")
	}

	manager.mu.Lock()
	oldPairHost.closeErr = nil
	manager.schedulePairExpiryLocked(7, 0)
	manager.mu.Unlock()
	for range 100 {
		manager.mu.Lock()
		closed := manager.pairHost == nil
		manager.mu.Unlock()
		if closed {
			break
		}
		time.Sleep(time.Millisecond)
	}
	manager.mu.Lock()
	defer manager.mu.Unlock()
	if manager.pairHost != nil || !oldPairHost.closed || oldPairHost.closeCalls < 2 {
		t.Fatalf("后续重试应关闭过期配对主机：host=%v closed=%t calls=%d", manager.pairHost, oldPairHost.closed, oldPairHost.closeCalls)
	}
}

func TestReplaceManagedClientsRestartsWithFreeAndManagedUnion(t *testing.T) {
	freeKey := key.NewNode().Public().String()
	oldManagedKey := key.NewNode().Public().String()
	newManagedKey := key.NewNode().Public().String()
	oldHost := &fakeManagedHost{address: "old", publicKey: "old-public"}
	var started tunnel.HostConfig
	manager := &Manager{
		config:         Config{},
		host:           oldHost,
		clients:        []string{freeKey},
		managedClients: []string{oldManagedKey},
		startHost: func(config tunnel.HostConfig) (managedHost, error) {
			started = config
			return &fakeManagedHost{address: "new", publicKey: "new-public"}, nil
		},
	}

	status, err := manager.ReplaceManagedClients([]string{newManagedKey, newManagedKey})
	if err != nil {
		t.Fatal(err)
	}
	if !oldHost.closed {
		t.Fatal("替换托管策略前应关闭包含旧授权的稳定主机")
	}
	if !reflect.DeepEqual(started.AllowedClientKeys, []string{freeKey, newManagedKey}) {
		t.Fatalf("稳定主机白名单未合并免费与托管客户端：%v", started.AllowedClientKeys)
	}
	if status.Address != "new" || status.PublicKey != "new-public" || status.PairedDeviceCount != 2 {
		t.Fatalf("替换后的状态异常：%+v", status)
	}
}

func TestReplaceManagedClientsFailsClosedWhenRestartFails(t *testing.T) {
	oldManagedKey := key.NewNode().Public().String()
	newManagedKey := key.NewNode().Public().String()
	oldHost := &fakeManagedHost{}
	manager := &Manager{
		host:           oldHost,
		managedClients: []string{oldManagedKey},
		startHost: func(tunnel.HostConfig) (managedHost, error) {
			return nil, errors.New("start failed")
		},
	}

	if _, err := manager.ReplaceManagedClients([]string{newManagedKey}); err == nil {
		t.Fatal("稳定主机重启失败时应返回错误")
	}
	if !oldHost.closed || manager.host != nil {
		t.Fatal("重启失败后不能继续运行包含旧托管授权的主机")
	}
	if !reflect.DeepEqual(manager.managedClients, []string{oldManagedKey}) {
		t.Fatal("失败的替换不应提交新的内存策略")
	}
}
