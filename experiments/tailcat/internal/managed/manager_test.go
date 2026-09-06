package managed

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
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

func TestStatusIncludesOnlyCurrentPairHostPublicKey(t *testing.T) {
	pairHost := &fakeManagedHost{address: "pair-address", publicKey: "nodekey:pair-public"}
	manager := &Manager{
		pairHost:      pairHost,
		pairExpiresAt: time.Now().Add(time.Minute),
	}

	status := manager.Status()
	if status.PairAddress != pairHost.address || status.PairPublicKey != pairHost.publicKey {
		t.Fatalf("有效配对状态缺少临时主机身份：%+v", status)
	}

	manager.pairExpiresAt = time.Now().Add(-time.Second)
	status = manager.Status()
	if status.PairAddress != "" || status.PairPublicKey != "" || status.PairExpiresAt != "" {
		t.Fatalf("过期配对状态不能暴露临时主机身份：%+v", status)
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

func TestResetClearsInMemoryClientsBeforeIdentityCleanupFailure(t *testing.T) {
	stateDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(stateDir, "clients.json"), []byte(`[]`), 0o600); err != nil {
		t.Fatal(err)
	}
	// 非空目录无法用 os.Remove 删除，用它稳定模拟 clients.json 已清理后
	// host.private.json 清理失败的路径。
	identityDirectory := filepath.Join(stateDir, "host.private.json")
	if err := os.Mkdir(identityDirectory, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(identityDirectory, "keep"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	oldHost := &fakeManagedHost{}
	manager := &Manager{
		config:         Config{StateDir: stateDir},
		host:           oldHost,
		clients:        []string{key.NewNode().Public().String()},
		managedClients: []string{key.NewNode().Public().String()},
	}

	if _, err := manager.Reset(); err == nil {
		t.Fatal("身份文件清理失败时 reset 应返回错误")
	}
	if !oldHost.closed || manager.host != nil || len(manager.clients) != 0 || len(manager.managedClients) != 0 {
		t.Fatalf("文件清理失败前必须清空运行时白名单：closed=%t host=%v clients=%v managed=%v", oldHost.closed, manager.host, manager.clients, manager.managedClients)
	}
	if _, err := os.Stat(filepath.Join(stateDir, "clients.json")); !os.IsNotExist(err) {
		t.Fatalf("持久白名单应在身份文件前删除：%v", err)
	}
}

func TestResetContinuesStableRevocationAfterPairingFileCleanupFailure(t *testing.T) {
	stateDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(stateDir, "clients.json"), []byte(`[]`), 0o600); err != nil {
		t.Fatal(err)
	}
	pairIdentityDirectory := filepath.Join(stateDir, "pair.private.json")
	if err := os.Mkdir(pairIdentityDirectory, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(pairIdentityDirectory, "keep"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	oldPairHost := &fakeManagedHost{}
	oldStableHost := &fakeManagedHost{}
	newStableHost := &fakeManagedHost{address: "new"}
	var started tunnel.HostConfig
	manager := &Manager{
		config:         Config{StateDir: stateDir},
		host:           oldStableHost,
		pairHost:       oldPairHost,
		clients:        []string{key.NewNode().Public().String()},
		managedClients: []string{key.NewNode().Public().String()},
		startHost: func(config tunnel.HostConfig) (managedHost, error) {
			started = config
			return newStableHost, nil
		},
	}

	status, err := manager.Reset()
	if err == nil || !strings.Contains(err.Error(), "pair.private.json") {
		t.Fatalf("配对文件清理失败应返回明确错误：%v", err)
	}
	if !oldPairHost.closed || manager.pairHost != nil {
		t.Fatal("配对主机关闭成功后不能因文件清理失败恢复")
	}
	if !oldStableHost.closed || manager.host != newStableHost || status.Address != "new" {
		t.Fatalf("配对文件清理失败后仍应重建空白稳定主机：closed=%t current=%t status=%+v", oldStableHost.closed, manager.host == newStableHost, status)
	}
	if len(manager.clients) != 0 || len(manager.managedClients) != 0 || len(started.AllowedClientKeys) != 0 {
		t.Fatalf("稳定主机必须撤销全部白名单：free=%v managed=%v started=%v", manager.clients, manager.managedClients, started.AllowedClientKeys)
	}
	if _, statErr := os.Stat(filepath.Join(stateDir, "clients.json")); !os.IsNotExist(statErr) {
		t.Fatalf("持久免费白名单必须删除：%v", statErr)
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
