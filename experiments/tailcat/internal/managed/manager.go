package managed

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/gaixianggeng/mimi-remote/experiments/tailcat/internal/tunnel"
)

const Version = "0.1"

type Config struct {
	TargetAddr  string
	RemotePort  uint16
	StateDir    string
	ControlPath string
	DERPMapURL  string
}

type Status struct {
	Version           string `json:"version"`
	Running           bool   `json:"running"`
	Address           string `json:"address,omitempty"`
	PairAddress       string `json:"pair_address,omitempty"`
	PairExpiresAt     string `json:"pair_expires_at,omitempty"`
	PairedDeviceCount int    `json:"paired_device_count"`
}

type Manager struct {
	mu             sync.Mutex
	config         Config
	host           *tunnel.Host
	pairHost       *tunnel.Host
	pairExpiresAt  time.Time
	pairGeneration uint64
	clients        []string
	server         *http.Server
	listener       net.Listener
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
	m := &Manager{config: config, clients: clients}
	if err := m.startStableLocked(); err != nil {
		return nil, err
	}
	if err := m.startControl(); err != nil {
		_ = m.host.Close()
		return nil, err
	}
	return m, nil
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
	m.closePairLocked()
	pairIdentity := filepath.Join(m.config.StateDir, "pair.private.json")
	pairAddress := filepath.Join(m.config.StateDir, "pair.address")
	_ = os.Remove(pairIdentity)
	_ = os.Remove(pairAddress)
	host, err := tunnel.StartHost(tunnel.HostConfig{
		TargetAddr:      m.config.TargetAddr,
		RemotePort:      m.config.RemotePort,
		IdentityPath:    pairIdentity,
		AddressPath:     pairAddress,
		AllowAllClients: true,
		DERPMapURL:      m.config.DERPMapURL,
	})
	if err != nil {
		return Status{}, fmt.Errorf("启动短期 Tailcat 配对服务：%w", err)
	}
	m.pairHost = host
	m.pairExpiresAt = time.Now().UTC().Add(ttl)
	m.pairGeneration++
	generation := m.pairGeneration
	time.AfterFunc(ttl, func() {
		m.mu.Lock()
		defer m.mu.Unlock()
		if m.pairGeneration == generation {
			m.closePairLocked()
		}
	})
	return m.statusLocked(), nil
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
	if err := m.host.AddAllowedClient(rawKey); err != nil {
		return Status{}, err
	}
	next := append(append([]string(nil), m.clients...), rawKey)
	if err := saveClients(filepath.Join(m.config.StateDir, "clients.json"), next); err != nil {
		return Status{}, err
	}
	m.clients = next
	return m.statusLocked(), nil
}

func (m *Manager) Reset() (Status, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.closePairLocked()
	if m.host != nil {
		_ = m.host.Close()
		m.host = nil
	}
	for _, name := range []string{"host.private.json", "host.address", "clients.json"} {
		if err := os.Remove(filepath.Join(m.config.StateDir, name)); err != nil && !os.IsNotExist(err) {
			return Status{}, fmt.Errorf("重置 Tailcat %s：%w", name, err)
		}
	}
	m.clients = nil
	if err := m.startStableLocked(); err != nil {
		return Status{}, err
	}
	return m.statusLocked(), nil
}

func (m *Manager) Close() error {
	m.mu.Lock()
	if m.server != nil {
		_ = m.server.Close()
	}
	if m.listener != nil {
		_ = m.listener.Close()
	}
	m.closePairLocked()
	var err error
	if m.host != nil {
		err = m.host.Close()
		m.host = nil
	}
	m.mu.Unlock()
	_ = os.Remove(m.config.ControlPath)
	return err
}

func (m *Manager) startStableLocked() error {
	host, err := tunnel.StartHost(tunnel.HostConfig{
		TargetAddr:        m.config.TargetAddr,
		RemotePort:        m.config.RemotePort,
		IdentityPath:      filepath.Join(m.config.StateDir, "host.private.json"),
		AddressPath:       filepath.Join(m.config.StateDir, "host.address"),
		AllowedClientKeys: append([]string(nil), m.clients...),
		DERPMapURL:        m.config.DERPMapURL,
	})
	if err != nil {
		return fmt.Errorf("启动稳定 Tailcat 服务：%w", err)
	}
	m.host = host
	return nil
}

func (m *Manager) closePairLocked() {
	if m.pairHost != nil {
		_ = m.pairHost.Close()
		m.pairHost = nil
	}
	m.pairExpiresAt = time.Time{}
	_ = os.Remove(filepath.Join(m.config.StateDir, "pair.private.json"))
	_ = os.Remove(filepath.Join(m.config.StateDir, "pair.address"))
}

func (m *Manager) statusLocked() Status {
	status := Status{
		Version:           Version,
		Running:           m.host != nil,
		PairedDeviceCount: len(m.clients),
	}
	if m.host != nil {
		status.Address = m.host.Address()
	}
	if m.pairHost != nil && time.Now().Before(m.pairExpiresAt) {
		status.PairAddress = m.pairHost.Address()
		status.PairExpiresAt = m.pairExpiresAt.Format(time.RFC3339Nano)
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
	mux.HandleFunc("/pair", m.pairHandler)
	mux.HandleFunc("/allow", m.allowHandler)
	mux.HandleFunc("/reset", m.resetHandler)
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
	status, err := m.StartPairing(10 * time.Minute)
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

func (m *Manager) resetHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	status, err := m.Reset()
	writeResult(w, status, err)
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

func RunUntilCanceled(ctx context.Context, config Config) error {
	manager, err := Start(config)
	if err != nil {
		return err
	}
	defer manager.Close()
	<-ctx.Done()
	return nil
}
