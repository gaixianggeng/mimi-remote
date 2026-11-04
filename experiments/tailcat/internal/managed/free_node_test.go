package managed

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/experiments/tailcat/internal/tunnel"
	"tailscale.com/types/key"
)

// recordingStarter 按身份文件区分节点，记录每个节点启动时的放行名单。
type recordingStarter struct {
	mu      sync.Mutex
	started map[string][]tunnel.HostConfig
	hosts   map[string]*fakeManagedHost
	fail    map[string]error
}

func newRecordingStarter() *recordingStarter {
	return &recordingStarter{
		started: make(map[string][]tunnel.HostConfig),
		hosts:   make(map[string]*fakeManagedHost),
		fail:    make(map[string]error),
	}
}

func (r *recordingStarter) start(config tunnel.HostConfig) (managedHost, error) {
	name := strings.TrimSuffix(filepath.Base(config.IdentityPath), ".private.json")
	r.mu.Lock()
	defer r.mu.Unlock()
	r.started[name] = append(r.started[name], config)
	if err := r.fail[name]; err != nil {
		return nil, err
	}
	host := &fakeManagedHost{address: name + "-address", publicKey: name + "-key"}
	r.hosts[name] = host
	return host, nil
}

func (r *recordingStarter) host(name string) *fakeManagedHost {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.hosts[name]
}

func newFreeNodeManager(t *testing.T, starter *recordingStarter, clients []string) *Manager {
	t.Helper()
	manager := &Manager{
		config: Config{
			StateDir: t.TempDir(), DERPMapURL: "https://official.example/map",
			FreeNode: true, FreeDERPMapURL: "https://free.example/map",
		},
		clients:   clients,
		startHost: starter.start,
		closing:   make(chan struct{}),
	}
	if err := manager.startStableLocked(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = manager.Close() })
	return manager
}

func startFreeNodeAndWait(t *testing.T, manager *Manager) {
	t.Helper()
	manager.mu.Lock()
	manager.startFreeNodeLoopLocked()
	manager.mu.Unlock()
	deadline := time.Now().Add(5 * time.Second)
	for manager.Status().FreeAddress == "" {
		if time.Now().After(deadline) {
			t.Fatal("免费节点没有启动")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func TestFreeClientsStayOutOfManagedHost(t *testing.T) {
	freeKey := key.NewNode().Public().String()
	managedKey := key.NewNode().Public().String()
	newFreeKey := key.NewNode().Public().String()
	starter := newRecordingStarter()
	manager := newFreeNodeManager(t, starter, []string{freeKey})
	startFreeNodeAndWait(t, manager)

	if got := starter.started["host"][0].AllowedClientKeys; len(got) != 0 {
		t.Fatalf("托管节点不能带免费白名单启动：%v", got)
	}
	if got := starter.started["free"][0].AllowedClientKeys; !reflect.DeepEqual(got, []string{freeKey}) {
		t.Fatalf("免费节点应沿用已配对设备：%v", got)
	}
	if config := starter.started["free"][0]; config.DERPMapURL != "https://free.example/map" || config.AllowAllClients {
		t.Fatalf("免费节点中继或放行范围错误：%+v", config)
	}

	if _, err := manager.AllowClient(newFreeKey); err != nil {
		t.Fatal(err)
	}
	if got := starter.host("host").added; len(got) != 0 {
		t.Fatalf("不带授权的设备不能进托管节点：%v", got)
	}
	if got := starter.host("free").added; !reflect.DeepEqual(got, []string{newFreeKey}) {
		t.Fatalf("新设备应加入免费节点：%v", got)
	}

	// 控制面撤销托管设备时重启托管节点，新名单同样不能混入免费设备。
	if _, err := manager.ReplaceManagedClients([]string{managedKey}); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.ReplaceManagedClients(nil); err != nil {
		t.Fatal(err)
	}
	starts := starter.started["host"]
	if got := starts[len(starts)-1].AllowedClientKeys; len(got) != 0 {
		t.Fatalf("重启后的托管节点混入了免费设备：%v", got)
	}
	if got := starter.host("free").added; !reflect.DeepEqual(got, []string{newFreeKey}) {
		t.Fatalf("托管名单变化不能影响免费节点：%v", got)
	}
	if status := manager.Status(); status.Address != "host-address" || status.FreeAddress != "free-address" {
		t.Fatalf("状态应分别给出两个节点：%+v", status)
	}
}

func TestFreeNodeFailureDoesNotBlockManagedPairing(t *testing.T) {
	starter := newRecordingStarter()
	starter.fail["free"] = errors.New("默认中继不可达")
	manager := newFreeNodeManager(t, starter, nil)
	manager.mu.Lock()
	manager.startFreeNodeLoopLocked()
	manager.mu.Unlock()

	status, err := manager.StartPairing(time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if status.PairAddress != "pair-address" || status.FreePairAddress != "" || status.FreeAddress != "" {
		t.Fatalf("免费节点不可用时二维码只带托管节点：%+v", status)
	}
	if _, err := manager.AllowClient(key.NewNode().Public().String()); !errors.Is(err, errFreeNodeNotReady) {
		t.Fatalf("免费节点未就绪时不能把设备放进托管节点：%v", err)
	}
	if got := starter.host("host").added; len(got) != 0 {
		t.Fatalf("托管节点被写入了免费设备：%v", got)
	}
}

func TestPairingStartsBothNodesAndClosesThemTogether(t *testing.T) {
	starter := newRecordingStarter()
	manager := newFreeNodeManager(t, starter, nil)
	startFreeNodeAndWait(t, manager)

	status, err := manager.StartPairing(time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if status.PairAddress != "pair-address" || status.FreePairAddress != "free-pair-address" {
		t.Fatalf("二维码应同时带两个配对节点：%+v", status)
	}
	config := starter.started["free-pair"][0]
	if !config.AllowAllClients || config.DERPMapURL != "https://free.example/map" {
		t.Fatalf("免费配对节点配置错误：%+v", config)
	}
	freePair := starter.host("free-pair")
	if err := os.WriteFile(filepath.Join(manager.config.StateDir, "free-pair.address"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	manager.mu.Lock()
	err = manager.closePairLocked()
	manager.mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	if !freePair.closed {
		t.Fatal("临时节点放行任意客户端，过期时必须一起关闭")
	}
	if _, err := os.Stat(filepath.Join(manager.config.StateDir, "free-pair.address")); !os.IsNotExist(err) {
		t.Fatalf("免费配对状态没有清理：%v", err)
	}
	if status := manager.Status(); status.FreePairAddress != "" || status.FreeAddress == "" {
		t.Fatalf("关闭配对不能影响免费稳定节点：%+v", status)
	}
}

func TestResetRevokesFreeNodeAndItsClients(t *testing.T) {
	freeKey := key.NewNode().Public().String()
	starter := newRecordingStarter()
	manager := newFreeNodeManager(t, starter, []string{freeKey})
	startFreeNodeAndWait(t, manager)
	oldFree := starter.host("free")

	if _, err := manager.Reset(); err != nil {
		t.Fatal(err)
	}
	if !oldFree.closed {
		t.Fatal("重置必须关闭旧免费节点")
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		starter.mu.Lock()
		starts := append([]tunnel.HostConfig(nil), starter.started["free"]...)
		starter.mu.Unlock()
		if len(starts) == 2 {
			if len(starts[1].AllowedClientKeys) != 0 {
				t.Fatalf("重置后免费节点不能保留旧设备：%v", starts[1].AllowedClientKeys)
			}
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("重置后没有重新拉起免费节点：%d", len(starts))
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// 重置时免费节点可能正在后台启动。启动会写身份文件并放行旧白名单，重置必须等它结束再清理。
func TestResetWaitsForInFlightFreeNodeStart(t *testing.T) {
	revokedKey := key.NewNode().Public().String()
	starter := newRecordingStarter()
	entered := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once
	startHost := func(config tunnel.HostConfig) (managedHost, error) {
		if filepath.Base(config.IdentityPath) == "free.private.json" {
			first := false
			once.Do(func() { first = true })
			if first {
				close(entered)
				<-release
				if err := os.WriteFile(config.IdentityPath, []byte("stale"), 0o600); err != nil {
					return nil, err
				}
			}
		}
		return starter.start(config)
	}
	manager := &Manager{
		config:    Config{StateDir: t.TempDir(), FreeNode: true},
		clients:   []string{revokedKey},
		startHost: startHost,
		closing:   make(chan struct{}),
	}
	if err := manager.startStableLocked(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = manager.Close() })
	manager.mu.Lock()
	manager.startFreeNodeLoopLocked()
	manager.mu.Unlock()
	<-entered

	resetDone := make(chan error, 1)
	go func() {
		_, err := manager.Reset()
		resetDone <- err
	}()
	select {
	case <-resetDone:
		t.Fatal("重置不能在免费节点启动途中清理身份")
	case <-time.After(100 * time.Millisecond):
	}
	close(release)
	if err := <-resetDone; err != nil {
		t.Fatal(err)
	}
	if identity, err := os.ReadFile(filepath.Join(manager.config.StateDir, "free.private.json")); err == nil {
		t.Fatalf("重置后残留了旧身份：%q", identity)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		starter.mu.Lock()
		starts := append([]tunnel.HostConfig(nil), starter.started["free"]...)
		starter.mu.Unlock()
		if len(starts) == 2 {
			if len(starts[1].AllowedClientKeys) != 0 {
				t.Fatalf("重置后的免费节点放行了已撤销设备：%v", starts[1].AllowedClientKeys)
			}
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("重置后没有重新拉起免费节点：%d", len(starts))
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func TestSelfHostedManagerKeepsSingleNode(t *testing.T) {
	clientKey := key.NewNode().Public().String()
	starter := newRecordingStarter()
	manager := &Manager{
		config:    Config{StateDir: t.TempDir()},
		clients:   []string{clientKey},
		startHost: starter.start,
		closing:   make(chan struct{}),
	}
	if err := manager.startStableLocked(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = manager.Close() })
	manager.startFreeNodeLoopLocked()
	if _, err := manager.StartPairing(time.Minute); err != nil {
		t.Fatal(err)
	}
	if got := starter.started["host"][0].AllowedClientKeys; !reflect.DeepEqual(got, []string{clientKey}) {
		t.Fatalf("自建模式的稳定节点仍要放行已配对设备：%v", got)
	}
	if len(starter.started["free"]) != 0 || len(starter.started["free-pair"]) != 0 {
		t.Fatal("自建模式不应多起节点")
	}
}
