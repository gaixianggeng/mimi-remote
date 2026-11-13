package managed

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/gaixianggeng/mimi-remote/experiments/tailcat/internal/tunnel"
	"github.com/tailscale/tailcat"
	"tailscale.com/tailcfg"
)

const (
	Version             = "0.1"
	pairCloseRetryDelay = time.Second
	// 配对节点沿用已知中继，通常很快。免费配对节点只是多一条路，不能拖垮 /pair 的预算。
	freePairStartTimeout = 8 * time.Second
	freeNodeRetryBase    = 5 * time.Second
	freeNodeRetryMax     = 5 * time.Minute
)

var errFreeNodeNotReady = errors.New("免费线路尚未就绪，请稍后重试")

type Config struct {
	TargetAddr  string
	RemotePort  uint16
	StateDir    string
	ControlPath string
	DERPMapURL  string
	// FreeNode 表示稳定节点走托管中继，另起一个免费节点。托管中继只放行开通过的设备，
	// 没开通的设备走免费节点。clients.json 属于免费节点，托管白名单只来自控制面，两边不混用。
	FreeNode       bool
	FreeDERPMapURL string
	// Events 接收稳定节点的连接事件。短期配对节点不接：它们 10 分钟就过期，且每次换身份。
	Events func(tunnel.HostEvent)
}

type managedHost interface {
	AddAllowedClient(string) error
	Address() string
	PublicKey() string
	Close() error
}

type hostStarter func(tunnel.HostConfig) (managedHost, error)

type Status struct {
	Version           string `json:"version"`
	InstanceID        string `json:"instance_id"`
	Running           bool   `json:"running"`
	Address           string `json:"address,omitempty"`
	PublicKey         string `json:"public_key,omitempty"`
	PairAddress       string `json:"pair_address,omitempty"`
	PairPublicKey     string `json:"pair_public_key,omitempty"`
	PairExpiresAt     string `json:"pair_expires_at,omitempty"`
	PairedDeviceCount int    `json:"paired_device_count"`
	FreeAddress       string `json:"free_address,omitempty"`
	FreePairAddress   string `json:"free_pair_address,omitempty"`
}

type Manager struct {
	mu             sync.Mutex
	config         Config
	host           managedHost
	pairHost       managedHost
	freeHost       managedHost
	freePairHost   managedHost
	freeGeneration uint64
	// freeStartMu 串行免费节点启动与重置，加锁顺序固定为先它后 mu。
	freeStartMu    sync.Mutex
	closing        chan struct{}
	closeOnce      sync.Once
	pairExpiresAt  time.Time
	pairGeneration uint64
	clients        []string
	managedClients []string
	startHost      hostStarter
	instanceID     string
	server         *http.Server
	listener       net.Listener
	shutdown       chan struct{}
	shutdownOnce   sync.Once
}

func Start(config Config) (*Manager, error) {
	if config.StateDir == "" || config.ControlPath == "" {
		return nil, errors.New("Tailcat 托管服务需要状态目录和控制 socket")
	}
	if err := os.MkdirAll(config.StateDir, 0o700); err != nil {
		return nil, fmt.Errorf("创建 Tailcat 状态目录：%w", err)
	}
	clients, err := loadClients(filepath.Join(config.StateDir, "clients.json"))
	if err != nil {
		return nil, err
	}
	instanceID, err := newInstanceID()
	if err != nil {
		return nil, fmt.Errorf("生成 Tailcat sidecar 实例身份：%w", err)
	}
	m := &Manager{
		config:     config,
		clients:    clients,
		instanceID: instanceID,
		shutdown:   make(chan struct{}),
		closing:    make(chan struct{}),
		startHost: func(config tunnel.HostConfig) (managedHost, error) {
			return tunnel.StartHost(config)
		},
	}
	if err := m.startStableLocked(); err != nil {
		return nil, err
	}
	if err := m.startControl(); err != nil {
		_ = m.host.Close()
		return nil, err
	}
	m.startFreeNodeLoopLocked()
	return m, nil
}

// startFreeNodeLoopLocked 在后台拉起免费节点。默认中继要先拉取节点表，首次可能很慢或暂时
// 不可达，这些都不能影响托管节点就绪，所以失败时只退避重试，二维码暂时不带免费节点。
func (m *Manager) startFreeNodeLoopLocked() {
	if !m.config.FreeNode {
		return
	}
	m.freeGeneration++
	go m.runFreeNode(m.freeGeneration)
}

func (m *Manager) runFreeNode(generation uint64) {
	delay := freeNodeRetryBase
	for {
		if m.startFreeNode(generation) {
			return
		}
		select {
		case <-m.closing:
			return
		case <-time.After(delay):
		}
		delay = min(delay*2, freeNodeRetryMax)
	}
}

// startFreeNode 全程持有 freeStartMu：启动时会写身份文件并按白名单放行，重置必须等它结束再清理，
// 否则晚到的启动会写回旧身份，或者短暂放行已撤销的设备。返回 false 表示要稍后重试。
func (m *Manager) startFreeNode(generation uint64) bool {
	m.freeStartMu.Lock()
	defer m.freeStartMu.Unlock()
	m.mu.Lock()
	current := m.freeGeneration == generation && !m.closingLocked()
	clients := append([]string(nil), m.clients...)
	m.mu.Unlock()
	if !current {
		return true
	}
	host, err := m.startHost(tunnel.HostConfig{
		TargetAddr:        m.config.TargetAddr,
		RemotePort:        m.config.RemotePort,
		IdentityPath:      filepath.Join(m.config.StateDir, "free.private.json"),
		AddressPath:       filepath.Join(m.config.StateDir, "free.address"),
		AllowedClientKeys: clients,
		DERPMapURL:        m.config.FreeDERPMapURL,
		Events:            m.config.Events,
	})
	if err != nil {
		log.Printf("免费节点启动失败，稍后重试：%v", err)
		return false
	}
	m.mu.Lock()
	closing := m.closingLocked()
	if !closing {
		m.freeHost = host
	}
	m.mu.Unlock()
	if closing {
		_ = host.Close()
	}
	return true
}

func (m *Manager) closingLocked() bool {
	select {
	case <-m.closing:
		return true
	default:
		return false
	}
}

func (m *Manager) Status() Status {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.statusLocked()
}

func (m *Manager) StartPairing(ttl time.Duration) (Status, error) {
	if ttl <= 0 || ttl > 10*time.Minute {
		ttl = 10 * time.Minute
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.closePairLocked(); err != nil {
		return Status{}, fmt.Errorf("关闭旧 Tailcat 配对服务：%w", err)
	}
	pairIdentity := filepath.Join(m.config.StateDir, "pair.private.json")
	pairAddress := filepath.Join(m.config.StateDir, "pair.address")
	_ = os.Remove(pairIdentity)
	_ = os.Remove(pairAddress)
	host, err := m.startHost(tunnel.HostConfig{
		TargetAddr:      m.config.TargetAddr,
		RemotePort:      m.config.RemotePort,
		IdentityPath:    pairIdentity,
		AddressPath:     pairAddress,
		AllowAllClients: true,
		DERPMapURL:      m.config.DERPMapURL,
		Region:          hostRegion(m.host),
	})
	if err != nil {
		return Status{}, fmt.Errorf("启动短期 Tailcat 配对服务：%w", err)
	}
	m.pairHost = host
	m.startFreePairLocked()
	m.pairExpiresAt = time.Now().UTC().Add(ttl)
	m.pairGeneration++
	generation := m.pairGeneration
	m.schedulePairExpiryLocked(generation, ttl)
	return m.statusLocked(), nil
}

// startFreePairLocked 给没开通的设备准备免费配对节点。失败或超时只是二维码少一条路，
// 不影响托管配对；超时后晚到的节点没人会用，直接关掉，不能留下放行任意客户端的入口。
func (m *Manager) startFreePairLocked() {
	if !m.config.FreeNode || m.freeHost == nil {
		return
	}
	type startResult struct {
		host managedHost
		err  error
	}
	config := tunnel.HostConfig{
		TargetAddr:      m.config.TargetAddr,
		RemotePort:      m.config.RemotePort,
		IdentityPath:    filepath.Join(m.config.StateDir, "free-pair.private.json"),
		AddressPath:     filepath.Join(m.config.StateDir, "free-pair.address"),
		AllowAllClients: true,
		DERPMapURL:      m.config.FreeDERPMapURL,
		Region:          hostRegion(m.freeHost),
	}
	_ = os.Remove(config.IdentityPath)
	_ = os.Remove(config.AddressPath)
	started := make(chan startResult, 1)
	go func() {
		host, err := m.startHost(config)
		started <- startResult{host: host, err: err}
	}()
	timer := time.NewTimer(freePairStartTimeout)
	defer timer.Stop()
	select {
	case result := <-started:
		if result.err != nil {
			log.Printf("免费配对节点启动失败：%v", result.err)
			return
		}
		m.freePairHost = result.host
	case <-timer.C:
		log.Printf("免费配对节点 %s 内未就绪，本次二维码只带托管节点", freePairStartTimeout)
		go func() {
			if result := <-started; result.err == nil {
				_ = result.host.Close()
			}
		}()
	}
}

// 配对节点与稳定节点使用同一个引导中继，避免每次生成二维码都重新运行
// DERP 延迟探测。只复用公开路由信息；临时身份仍在每次 StartPairing 时轮换。
// 地址未内嵌中继时返回 nil，让 StartHost 沿用配置的中继发现路径。
func hostRegion(host managedHost) *tailcfg.DERPRegion {
	if host == nil {
		return nil
	}
	info, err := tailcat.ParseAddr(tailcat.Addr(host.Address()))
	if err != nil || len(info.Region) != 1 || len(info.Region[0].Nodes) == 0 {
		return nil
	}
	return info.Region[0]
}

func (m *Manager) AllowClient(rawKey string) (Status, error) {
	rawKey = strings.TrimSpace(rawKey)
	if _, err := tunnel.ParsePublicKey(rawKey); err != nil {
		return Status{}, err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, existing := range m.clients {
		if existing == rawKey {
			return m.statusLocked(), nil
		}
	}
	target := m.host
	if m.config.FreeNode {
		target = m.freeHost
		if target == nil {
			return Status{}, errFreeNodeNotReady
		}
	} else if target == nil {
		return Status{}, errors.New("Tailcat 稳定服务未运行")
	}
	if err := target.AddAllowedClient(rawKey); err != nil {
		return Status{}, err
	}
	next := append(append([]string(nil), m.clients...), rawKey)
	if err := saveClients(filepath.Join(m.config.StateDir, "clients.json"), next); err != nil {
		return Status{}, err
	}
	m.clients = next
	return m.statusLocked(), nil
}

// ReplaceManagedClients 用控制面返回的完整集合替换托管白名单。Tailcat 上游
// 支持原地追加，但不支持删除，因此只有撤销客户端时才重启稳定主机。
func (m *Manager) ReplaceManagedClients(rawKeys []string) (Status, error) {
	next, err := normalizeClientKeys(rawKeys)
	if err != nil {
		return Status{}, err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if clientKeySetsEqual(m.managedClients, next) && m.host != nil {
		return m.statusLocked(), nil
	}
	if m.host != nil && clientKeysContainAll(next, m.managedClients) {
		// 纯新增不会扩大到控制面集合之外，可以在现有引擎上逐项授权。
		// 与免费白名单重叠的键已经生效，无需重复追加。
		active := m.stableClientsLocked(m.managedClients)
		applied := append([]string(nil), m.managedClients...)
		for _, rawKey := range next {
			if clientKeysContainAll(m.managedClients, []string{rawKey}) {
				continue
			}
			if !clientKeysContainAll(active, []string{rawKey}) {
				if err := m.host.AddAllowedClient(rawKey); err != nil {
					// 前面的追加已经生效且上游不能删除。记录实际集合，确保控制面
					// 随后撤销时会识别到删除并通过重启关闭授权。
					m.managedClients = applied
					return Status{}, err
				}
				active = append(active, rawKey)
			}
			applied = append(applied, rawKey)
		}
		m.managedClients = next
		return m.statusLocked(), nil
	}
	if m.host != nil {
		if err := m.host.Close(); err != nil {
			// Close 失败时旧主机可能仍在接受连接。保留句柄并中止替换，
			// 让下一次策略同步可以继续重试关闭，不能启动第二个主机。
			return Status{}, fmt.Errorf("关闭旧稳定 Tailcat 服务：%w", err)
		}
		m.host = nil
	}
	host, err := m.startStableHostLocked(next)
	if err != nil {
		// 重启失败时保持关闭，不能重新启动仍包含已撤销客户端的旧策略。
		return Status{}, err
	}
	m.host = host
	m.managedClients = next
	return m.statusLocked(), nil
}

func (m *Manager) Reset() (Status, error) {
	m.freeStartMu.Lock()
	defer m.freeStartMu.Unlock()
	m.mu.Lock()
	defer m.mu.Unlock()
	pairErr := m.closePairLocked()
	if pairErr != nil {
		pairErr = fmt.Errorf("关闭待重置 Tailcat 配对服务：%w", pairErr)
	}
	if m.host != nil {
		if err := m.host.Close(); err != nil {
			return Status{}, errors.Join(pairErr, fmt.Errorf("关闭待重置 Tailcat 服务：%w", err))
		}
		m.host = nil
	}
	m.freeGeneration++
	if m.freeHost != nil {
		if err := m.freeHost.Close(); err != nil {
			return Status{}, errors.Join(pairErr, fmt.Errorf("关闭待重置免费节点：%w", err))
		}
		m.freeHost = nil
	}
	// 稳定主机已经关闭后，先提交内存中的撤销结果并优先删除持久白名单。
	// 后续身份文件清理失败时，后台协调也只能用空集合重启。
	m.clients = nil
	m.managedClients = nil
	var cleanupErr error
	for _, name := range []string{"clients.json", "host.private.json", "host.address", "free.private.json", "free.address"} {
		if err := os.Remove(filepath.Join(m.config.StateDir, name)); err != nil && !os.IsNotExist(err) {
			cleanupErr = errors.Join(cleanupErr, fmt.Errorf("重置 Tailcat %s：%w", name, err))
		}
	}
	if cleanupErr != nil {
		return Status{}, errors.Join(pairErr, cleanupErr)
	}
	if err := m.startStableLocked(); err != nil {
		return Status{}, errors.Join(pairErr, err)
	}
	m.startFreeNodeLoopLocked()
	return m.statusLocked(), pairErr
}

func (m *Manager) Close() error {
	m.closeOnce.Do(func() {
		if m.closing != nil {
			close(m.closing)
		}
	})
	m.mu.Lock()
	if m.server != nil {
		_ = m.server.Close()
	}
	if m.listener != nil {
		_ = m.listener.Close()
	}
	pairErr := m.closePairLocked()
	var hostErr, freeErr error
	if m.host != nil {
		hostErr = m.host.Close()
		if hostErr == nil {
			m.host = nil
		}
	}
	if m.freeHost != nil {
		freeErr = m.freeHost.Close()
		if freeErr == nil {
			m.freeHost = nil
		}
	}
	m.mu.Unlock()
	_ = os.Remove(m.config.ControlPath)
	return errors.Join(pairErr, hostErr, freeErr)
}

func (m *Manager) startStableLocked() error {
	host, err := m.startStableHostLocked(m.managedClients)
	if err != nil {
		return err
	}
	m.host = host
	return nil
}

// stableClientsLocked 是稳定节点的放行名单。有免费节点时 clients.json 只属于免费节点，
// 不进托管节点：托管中继上的放行名单必须完全来自控制面，免费白名单不能绕过订阅。
func (m *Manager) stableClientsLocked(managedClients []string) []string {
	if m.config.FreeNode {
		return mergeClientKeys(managedClients)
	}
	return mergeClientKeys(m.clients, managedClients)
}

func (m *Manager) startStableHostLocked(managedClients []string) (managedHost, error) {
	allowedClients := m.stableClientsLocked(managedClients)
	host, err := m.startHost(tunnel.HostConfig{
		TargetAddr:        m.config.TargetAddr,
		RemotePort:        m.config.RemotePort,
		IdentityPath:      filepath.Join(m.config.StateDir, "host.private.json"),
		AddressPath:       filepath.Join(m.config.StateDir, "host.address"),
		AllowedClientKeys: allowedClients,
		DERPMapURL:        m.config.DERPMapURL,
		Events:            m.config.Events,
	})
	if err != nil {
		return nil, fmt.Errorf("启动稳定 Tailcat 服务：%w", err)
	}
	return host, nil
}

func (m *Manager) schedulePairExpiryLocked(generation uint64, delay time.Duration) {
	time.AfterFunc(delay, func() {
		m.mu.Lock()
		defer m.mu.Unlock()
		if m.pairGeneration != generation {
			return
		}
		if err := m.closePairLocked(); err != nil {
			// 短期配对主机允许任意客户端接入。关闭失败时保留句柄并持续
			// 重试，不能因为第一次 Close 失败就让临时入口无限期存活。
			m.schedulePairExpiryLocked(generation, pairCloseRetryDelay)
		}
	})
}

func (m *Manager) closePairLocked() error {
	if m.pairHost != nil {
		if err := m.pairHost.Close(); err != nil {
			return err
		}
		m.pairHost = nil
	}
	if m.freePairHost != nil {
		if err := m.freePairHost.Close(); err != nil {
			return err
		}
		m.freePairHost = nil
	}
	m.pairExpiresAt = time.Time{}
	var cleanupErr error
	for _, name := range []string{"pair.private.json", "pair.address", "free-pair.private.json", "free-pair.address"} {
		if err := os.Remove(filepath.Join(m.config.StateDir, name)); err != nil && !os.IsNotExist(err) {
			cleanupErr = errors.Join(cleanupErr, fmt.Errorf("删除 Tailcat 配对状态 %s：%w", name, err))
		}
	}
	return cleanupErr
}

func (m *Manager) statusLocked() Status {
	status := Status{
		Version:           Version,
		InstanceID:        m.instanceID,
		Running:           m.host != nil,
		PairedDeviceCount: len(mergeClientKeys(m.clients, m.managedClients)),
	}
	if m.host != nil {
		status.Address = m.host.Address()
		status.PublicKey = m.host.PublicKey()
	}
	if m.pairHost != nil && time.Now().Before(m.pairExpiresAt) {
		status.PairAddress = m.pairHost.Address()
		status.PairPublicKey = m.pairHost.PublicKey()
		status.PairExpiresAt = m.pairExpiresAt.Format(time.RFC3339Nano)
		if m.freePairHost != nil {
			status.FreePairAddress = m.freePairHost.Address()
		}
	}
	if m.freeHost != nil {
		status.FreeAddress = m.freeHost.Address()
	}
	return status
}

func (m *Manager) startControl() error {
	_ = os.Remove(m.config.ControlPath)
	listener, err := net.Listen("unix", m.config.ControlPath)
	if err != nil {
		return fmt.Errorf("监听 Tailcat 控制 socket：%w", err)
	}
	if err := os.Chmod(m.config.ControlPath, 0o600); err != nil {
		_ = listener.Close()
		return fmt.Errorf("设置 Tailcat 控制 socket 权限：%w", err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/status", m.statusHandler)
	mux.HandleFunc("/node-ownership-proof", m.nodeOwnershipHandler)
	mux.HandleFunc("/pair", m.pairHandler)
	mux.HandleFunc("/allow", m.allowHandler)
	mux.HandleFunc("/managed-clients", m.managedClientsHandler)
	mux.HandleFunc("/reset", m.resetHandler)
	mux.HandleFunc("/shutdown", m.shutdownHandler)
	m.listener = listener
	m.server = &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() { _ = m.server.Serve(listener) }()
	return nil
}

func (m *Manager) statusHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	writeJSON(w, http.StatusOK, m.Status())
}

func (m *Manager) pairHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	// 首次配对要等中继授权临时节点，耗时不稳定。写到 stderr 由 agentd 收进日志，
	// 排查时能看到是节点启动慢还是控制通道慢。
	started := time.Now()
	status, err := m.StartPairing(10 * time.Minute)
	elapsed := time.Since(started).Round(time.Millisecond)
	if err != nil {
		log.Printf("pair: 短期配对节点启动失败（耗时 %s）：%v", elapsed, err)
	} else {
		log.Printf("pair: 短期配对节点启动耗时 %s", elapsed)
	}
	writeResult(w, status, err)
}

func (m *Manager) allowHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	var payload struct {
		PublicKey string `json:"public_key"`
	}
	if err := json.NewDecoder(req.Body).Decode(&payload); err != nil {
		writeResult(w, Status{}, errors.New("客户端公钥请求无效"))
		return
	}
	status, err := m.AllowClient(payload.PublicKey)
	writeResult(w, status, err)
}

func (m *Manager) managedClientsHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPut {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	var payload struct {
		PublicKeys []string `json:"public_keys"`
	}
	if err := json.NewDecoder(req.Body).Decode(&payload); err != nil {
		writeResult(w, Status{}, errors.New("托管客户端公钥请求无效"))
		return
	}
	status, err := m.ReplaceManagedClients(payload.PublicKeys)
	writeResult(w, status, err)
}

func (m *Manager) resetHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	status, err := m.Reset()
	writeResult(w, status, err)
}

// shutdownHandler 让 agentd 在 Windows 上正常停止辅助程序：Windows 不能向子进程投递
// SIGINT/SIGTERM，强杀会跳过关闭配对节点和清理控制 socket。先把响应写回，再触发退出，
// 避免 Close 关闭连接时 agentd 收不到确认。
func (m *Manager) shutdownHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]bool{"stopping": true})
	if flusher, ok := w.(http.Flusher); ok {
		flusher.Flush()
	}
	m.RequestShutdown()
}

// RequestShutdown 与收到中断信号等价，RunUntilCanceled 随后关闭全部节点并退出。
func (m *Manager) RequestShutdown() {
	m.shutdownOnce.Do(func() { close(m.shutdown) })
}

func writeResult(w http.ResponseWriter, status Status, err error) {
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, status)
}

func writeJSON(w http.ResponseWriter, code int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(value)
}

func loadClients(path string) ([]string, error) {
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("读取 Tailcat 客户端列表：%w", err)
	}
	var clients []string
	if err := json.Unmarshal(data, &clients); err != nil {
		return nil, fmt.Errorf("解析 Tailcat 客户端列表：%w", err)
	}
	for _, client := range clients {
		if _, err := tunnel.ParsePublicKey(client); err != nil {
			return nil, err
		}
	}
	return clients, nil
}

func saveClients(path string, clients []string) error {
	data, err := json.Marshal(clients)
	if err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".clients-*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o600); err != nil {
		_ = temporary.Close()
		return err
	}
	if _, err := temporary.Write(data); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(temporaryPath, path)
}

func normalizeClientKeys(rawKeys []string) ([]string, error) {
	seen := make(map[string]struct{}, len(rawKeys))
	keys := make([]string, 0, len(rawKeys))
	for _, rawKey := range rawKeys {
		key := strings.TrimSpace(rawKey)
		if _, err := tunnel.ParsePublicKey(key); err != nil {
			return nil, err
		}
		if _, exists := seen[key]; exists {
			continue
		}
		seen[key] = struct{}{}
		keys = append(keys, key)
	}
	return keys, nil
}

func mergeClientKeys(groups ...[]string) []string {
	seen := map[string]struct{}{}
	var merged []string
	for _, group := range groups {
		for _, key := range group {
			if _, exists := seen[key]; exists {
				continue
			}
			seen[key] = struct{}{}
			merged = append(merged, key)
		}
	}
	return merged
}

func clientKeySetsEqual(left, right []string) bool {
	return len(left) == len(right) && clientKeysContainAll(left, right)
}

func clientKeysContainAll(keys, required []string) bool {
	available := make(map[string]struct{}, len(keys))
	for _, key := range keys {
		available[key] = struct{}{}
	}
	for _, key := range required {
		if _, exists := available[key]; !exists {
			return false
		}
	}
	return true
}

func newInstanceID() (string, error) {
	random := make([]byte, 16)
	if _, err := rand.Read(random); err != nil {
		return "", err
	}
	return hex.EncodeToString(random), nil
}

func RunUntilCanceled(ctx context.Context, config Config) error {
	manager, err := Start(config)
	if err != nil {
		return err
	}
	defer manager.Close()
	select {
	case <-ctx.Done():
	case <-manager.shutdown:
	}
	return nil
}
