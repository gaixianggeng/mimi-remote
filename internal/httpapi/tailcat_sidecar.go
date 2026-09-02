package httpapi

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	agentsetup "github.com/gaixianggeng/mimi-remote/internal/setup"
)

const (
	// TailcatLocalControlHeader 携带只存在本机 0600 文件中的随机值。
	TailcatLocalControlHeader = "X-Mimi-Tailcat-Local-Control"
	tailcatSidecarBinary      = "mimi-tailcat-experiment"
	defaultTailcatPort        = 8787
)

type tailcatStatus struct {
	Enabled           bool   `json:"enabled"`
	Running           bool   `json:"running"`
	Version           string `json:"version,omitempty"`
	DERPMapURL        string `json:"derp_map_url,omitempty"`
	Address           string `json:"address,omitempty"`
	PairAddress       string `json:"pair_address,omitempty"`
	PairExpiresAt     string `json:"pair_expires_at,omitempty"`
	PairedDeviceCount int    `json:"paired_device_count"`
	Error             string `json:"error,omitempty"`
}

type tailcatSidecar interface {
	Status(context.Context) tailcatStatus
	Start(context.Context) error
	Stop(context.Context) error
	Pair(context.Context) (tailcatStatus, error)
	AllowClient(context.Context, string) (tailcatStatus, error)
	Reset(context.Context) (tailcatStatus, error)
	ConfigureDERPMap(context.Context, string) (tailcatStatus, error)
	Close()
}

type tailcatSidecarSupervisor struct {
	operationMu sync.Mutex
	mu          sync.Mutex
	config      config.TailcatConfig
	configPath  string
	stateDir    string
	controlPath string
	targetAddr  string
	cmd         *exec.Cmd
	done        chan struct{}
	starting    bool
	closing     bool
	lastError   string
}

func newTailcatSidecarSupervisor(cfg config.Config, configPath string) *tailcatSidecarSupervisor {
	stateDir, _ := tailcatStateDirectory(configPath)
	supervisor := &tailcatSidecarSupervisor{
		config:      cfg.Tailcat,
		configPath:  configPath,
		stateDir:    stateDir,
		controlPath: filepath.Join(stateDir, "control.sock"),
		targetAddr:  tailcatLoopbackTarget(cfg.Listen),
	}
	if stateDir != "" {
		if err := ensureTailcatLocalControlToken(stateDir); err != nil {
			supervisor.lastError = err.Error()
		}
	}
	return supervisor
}

func (s *tailcatSidecarSupervisor) Start(ctx context.Context) error {
	if s == nil {
		return errors.New("Tailcat 管理器未初始化")
	}
	s.operationMu.Lock()
	defer s.operationMu.Unlock()
	return s.start(ctx)
}

func (s *tailcatSidecarSupervisor) start(ctx context.Context) error {
	if s == nil {
		return errors.New("Tailcat 管理器未初始化")
	}
	s.mu.Lock()
	if s.closing {
		s.mu.Unlock()
		return errors.New("Tailcat 管理器正在关闭")
	}
	s.config.Enabled = true
	if s.cmd != nil {
		s.mu.Unlock()
		return nil
	}
	if s.starting {
		s.mu.Unlock()
		return errors.New("Tailcat 正在启动")
	}
	if s.stateDir == "" {
		s.mu.Unlock()
		return errors.New("Tailcat 缺少配置文件路径")
	}
	s.starting = true
	s.lastError = ""
	s.mu.Unlock()

	bin, err := resolveTailcatSidecarBinary(s.config.SidecarBin)
	if err != nil {
		s.finishStart(nil, err)
		return err
	}
	if err := os.MkdirAll(s.stateDir, 0o700); err != nil {
		err = fmt.Errorf("创建 Tailcat 状态目录：%w", err)
		s.finishStart(nil, err)
		return err
	}
	_ = os.Remove(s.controlPath)
	args := []string{
		"managed-host",
		"--target", s.targetAddr,
		"--port", strconv.Itoa(tailcatTargetPort(s.targetAddr)),
		"--state-dir", s.stateDir,
		"--control", s.controlPath,
	}
	if value := strings.TrimSpace(s.config.DERPMapURL); value != "" {
		args = append(args, "--derpmap-url", value)
	}
	cmd := exec.Command(bin, args...)
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	if err := cmd.Start(); err != nil {
		err = fmt.Errorf("启动 Tailcat sidecar：%w", err)
		s.finishStart(nil, err)
		return err
	}
	done := make(chan struct{})
	s.mu.Lock()
	s.cmd = cmd
	s.done = done
	s.mu.Unlock()
	go s.reap(cmd, done)

	readyCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	if err := s.waitUntilReady(readyCtx); err != nil {
		s.finishStart(cmd, err)
		_ = s.stopProcess(context.Background(), cmd, done)
		return err
	}
	s.finishStart(cmd, nil)
	return nil
}

func (s *tailcatSidecarSupervisor) finishStart(cmd *exec.Cmd, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.starting = false
	if err != nil {
		s.lastError = err.Error()
		if cmd != nil && s.cmd == cmd {
			s.cmd = nil
			s.done = nil
		}
	}
}

func (s *tailcatSidecarSupervisor) reap(cmd *exec.Cmd, done chan struct{}) {
	err := cmd.Wait()
	s.mu.Lock()
	if s.cmd == cmd {
		s.cmd = nil
		s.done = nil
		if !s.closing {
			if err != nil {
				s.lastError = "Tailcat sidecar 已退出：" + err.Error()
			} else {
				s.lastError = "Tailcat sidecar 已退出"
			}
		}
	}
	s.mu.Unlock()
	close(done)
}

func (s *tailcatSidecarSupervisor) Stop(ctx context.Context) error {
	if s == nil {
		return nil
	}
	s.operationMu.Lock()
	defer s.operationMu.Unlock()
	return s.stop(ctx)
}

func (s *tailcatSidecarSupervisor) stop(ctx context.Context) error {
	if s == nil {
		return nil
	}
	s.mu.Lock()
	s.config.Enabled = false
	cmd := s.cmd
	done := s.done
	s.lastError = ""
	s.mu.Unlock()
	if cmd == nil {
		_ = os.Remove(s.controlPath)
		return nil
	}
	return s.stopProcess(ctx, cmd, done)
}

func (s *tailcatSidecarSupervisor) stopProcess(ctx context.Context, cmd *exec.Cmd, done chan struct{}) error {
	if cmd == nil || cmd.Process == nil || done == nil {
		return nil
	}
	_ = cmd.Process.Signal(os.Interrupt)
	timer := time.NewTimer(3 * time.Second)
	defer timer.Stop()
	select {
	case <-done:
	case <-ctx.Done():
		_ = cmd.Process.Kill()
		return ctx.Err()
	case <-timer.C:
		_ = cmd.Process.Kill()
		<-done
	}
	_ = os.Remove(s.controlPath)
	return nil
}

func (s *tailcatSidecarSupervisor) Status(ctx context.Context) tailcatStatus {
	if s == nil {
		return tailcatStatus{}
	}
	s.mu.Lock()
	enabled := s.config.Enabled
	derpMapURL := s.config.DERPMapURL
	running := s.cmd != nil
	starting := s.starting
	lastError := s.lastError
	s.mu.Unlock()
	status := tailcatStatus{Enabled: enabled, Running: running, DERPMapURL: derpMapURL}
	if !enabled {
		return status
	}
	if running {
		if err := s.call(ctx, http.MethodGet, "/status", nil, &status); err == nil {
			status.Enabled = true
			status.DERPMapURL = derpMapURL
			return status
		} else if lastError == "" && !starting {
			lastError = err.Error()
		}
	}
	status.Running = false
	status.Error = lastError
	if starting && status.Error == "" {
		status.Error = "Tailcat 正在启动"
	}
	return status
}

func (s *tailcatSidecarSupervisor) Pair(ctx context.Context) (tailcatStatus, error) {
	if s == nil {
		return tailcatStatus{}, errors.New("Tailcat 管理器未初始化")
	}
	s.operationMu.Lock()
	defer s.operationMu.Unlock()
	var status tailcatStatus
	err := s.call(ctx, http.MethodPost, "/pair", nil, &status)
	s.applyConfigurationToStatus(&status)
	return status, err
}

func (s *tailcatSidecarSupervisor) AllowClient(ctx context.Context, publicKey string) (tailcatStatus, error) {
	if s == nil {
		return tailcatStatus{}, errors.New("Tailcat 管理器未初始化")
	}
	s.operationMu.Lock()
	defer s.operationMu.Unlock()
	var status tailcatStatus
	err := s.call(ctx, http.MethodPost, "/allow", map[string]string{"public_key": publicKey}, &status)
	s.applyConfigurationToStatus(&status)
	return status, err
}

func (s *tailcatSidecarSupervisor) Reset(ctx context.Context) (tailcatStatus, error) {
	if s == nil {
		return tailcatStatus{}, errors.New("Tailcat 管理器未初始化")
	}
	s.operationMu.Lock()
	defer s.operationMu.Unlock()
	var status tailcatStatus
	err := s.call(ctx, http.MethodPost, "/reset", nil, &status)
	s.applyConfigurationToStatus(&status)
	return status, err
}

func (s *tailcatSidecarSupervisor) applyConfigurationToStatus(status *tailcatStatus) {
	s.mu.Lock()
	defer s.mu.Unlock()
	status.Enabled = s.config.Enabled
	status.DERPMapURL = s.config.DERPMapURL
}

// ConfigureDERPMap 原子切换用户选择的 DERP Map。Tailcat 连接地址内嵌中继
// 区域，因此成功切换必须重建主机身份并清空配对；启动或写配置失败时恢复
// 原状态，不能让一次设置操作破坏现有远程入口。
func (s *tailcatSidecarSupervisor) ConfigureDERPMap(ctx context.Context, rawURL string) (tailcatStatus, error) {
	if s == nil {
		return tailcatStatus{}, errors.New("Tailcat 管理器未初始化")
	}
	s.operationMu.Lock()
	defer s.operationMu.Unlock()
	normalized, err := config.NormalizeTailcatDERPMapURL(rawURL)
	if err != nil {
		return s.Status(ctx), err
	}
	s.mu.Lock()
	if s.closing {
		s.mu.Unlock()
		return tailcatStatus{}, errors.New("Tailcat 管理器正在关闭")
	}
	if s.starting {
		s.mu.Unlock()
		return tailcatStatus{}, errors.New("Tailcat 正在启动")
	}
	previousConfig := s.config
	wasRunning := s.cmd != nil
	stateDir := s.stateDir
	s.mu.Unlock()
	if stateDir == "" {
		return tailcatStatus{}, errors.New("Tailcat 缺少配置文件路径")
	}
	previousURL, _ := config.NormalizeTailcatDERPMapURL(previousConfig.DERPMapURL)
	if normalized == previousURL {
		return s.Status(ctx), nil
	}

	snapshot, err := snapshotTailcatIdentityState(stateDir)
	if err != nil {
		return s.Status(ctx), err
	}
	if err := s.stopForReconfiguration(ctx); err != nil {
		// 请求可能在旧 sidecar 已停止后被取消。此时仍要用独立上下文
		// 恢复原身份和进程，避免一次取消破坏现有远程入口。
		return s.rollbackDERPMap(ctx, previousConfig, wasRunning, snapshot, err)
	}
	s.mu.Lock()
	s.config.DERPMapURL = normalized
	s.mu.Unlock()
	if err := clearTailcatIdentityState(stateDir); err != nil {
		return s.rollbackDERPMap(ctx, previousConfig, wasRunning, snapshot, err)
	}
	if previousConfig.Enabled {
		if err := s.start(ctx); err != nil {
			return s.rollbackDERPMap(ctx, previousConfig, wasRunning, snapshot, err)
		}
	}
	if _, err := agentsetup.ConfigureTailcatDERPMap(s.configPath, normalized); err != nil {
		return s.rollbackDERPMap(ctx, previousConfig, wasRunning, snapshot, err)
	}
	return s.Status(ctx), nil
}

func (s *tailcatSidecarSupervisor) stopForReconfiguration(ctx context.Context) error {
	s.mu.Lock()
	cmd := s.cmd
	done := s.done
	s.mu.Unlock()
	return s.stopProcess(ctx, cmd, done)
}

func (s *tailcatSidecarSupervisor) rollbackDERPMap(
	ctx context.Context,
	previousConfig config.TailcatConfig,
	wasRunning bool,
	snapshot tailcatIdentitySnapshot,
	applyError error,
) (tailcatStatus, error) {
	_ = s.stopForReconfiguration(context.Background())
	restoreError := restoreTailcatIdentityState(s.stateDir, snapshot)
	s.mu.Lock()
	s.config = previousConfig
	s.mu.Unlock()
	if restoreError == nil && wasRunning {
		// 新中继的就绪等待可能已经耗尽原请求 deadline。恢复必须使用独立
		// 的短期上下文，否则会留下 enabled 但未运行的旧配置。
		restoreCtx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
		restoreError = s.start(restoreCtx)
		cancel()
	}
	if restoreError != nil {
		return s.Status(ctx), fmt.Errorf("应用 Tailcat 中继失败：%v；恢复原中继也失败：%w", applyError, restoreError)
	}
	return s.Status(ctx), fmt.Errorf("应用 Tailcat 中继失败，已恢复原配置：%w", applyError)
}

var tailcatIdentityFiles = []string{
	"host.private.json",
	"host.address",
	"clients.json",
	"pair.private.json",
	"pair.address",
}

type tailcatIdentitySnapshot map[string][]byte

func snapshotTailcatIdentityState(stateDir string) (tailcatIdentitySnapshot, error) {
	snapshot := tailcatIdentitySnapshot{}
	for _, name := range tailcatIdentityFiles {
		data, err := os.ReadFile(filepath.Join(stateDir, name))
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return nil, fmt.Errorf("备份 Tailcat 状态：%w", err)
		}
		snapshot[name] = data
	}
	return snapshot, nil
}

func clearTailcatIdentityState(stateDir string) error {
	for _, name := range tailcatIdentityFiles {
		if err := os.Remove(filepath.Join(stateDir, name)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("清理 Tailcat %s：%w", name, err)
		}
	}
	return nil
}

func restoreTailcatIdentityState(stateDir string, snapshot tailcatIdentitySnapshot) error {
	if err := clearTailcatIdentityState(stateDir); err != nil {
		return err
	}
	for _, name := range tailcatIdentityFiles {
		data, exists := snapshot[name]
		if !exists {
			continue
		}
		if err := writeTailcatPrivateFile(filepath.Join(stateDir, name), data); err != nil {
			return fmt.Errorf("恢复 Tailcat %s：%w", name, err)
		}
	}
	return nil
}

func (s *tailcatSidecarSupervisor) Close() {
	if s == nil {
		return
	}
	s.operationMu.Lock()
	defer s.operationMu.Unlock()
	s.mu.Lock()
	s.closing = true
	cmd := s.cmd
	done := s.done
	s.mu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	_ = s.stopProcess(ctx, cmd, done)
}

func (s *tailcatSidecarSupervisor) waitUntilReady(ctx context.Context) error {
	ticker := time.NewTicker(50 * time.Millisecond)
	defer ticker.Stop()
	for {
		var status tailcatStatus
		if err := s.call(ctx, http.MethodGet, "/status", nil, &status); err == nil && status.Running {
			return nil
		}
		s.mu.Lock()
		running := s.cmd != nil
		s.mu.Unlock()
		if !running {
			return errors.New("Tailcat sidecar 在启动期间退出")
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("等待 Tailcat sidecar 就绪：%w", ctx.Err())
		case <-ticker.C:
		}
	}
}

func (s *tailcatSidecarSupervisor) call(ctx context.Context, method string, path string, payload any, result any) error {
	if s == nil || s.controlPath == "" {
		return errors.New("Tailcat 控制通道不可用")
	}
	var body io.Reader
	if payload != nil {
		encoded, err := json.Marshal(payload)
		if err != nil {
			return err
		}
		body = bytes.NewReader(encoded)
	}
	req, err := http.NewRequestWithContext(ctx, method, "http://tailcat.local"+path, body)
	if err != nil {
		return err
	}
	if payload != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	transport := &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "unix", s.controlPath)
		},
	}
	defer transport.CloseIdleConnections()
	client := http.Client{Transport: transport, Timeout: 5 * time.Second}
	response, err := client.Do(req)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		var failure struct {
			Error string `json:"error"`
		}
		_ = json.NewDecoder(io.LimitReader(response.Body, 16<<10)).Decode(&failure)
		if strings.TrimSpace(failure.Error) == "" {
			failure.Error = fmt.Sprintf("Tailcat 控制接口返回 HTTP %d", response.StatusCode)
		}
		return errors.New(failure.Error)
	}
	if result == nil {
		return nil
	}
	if err := json.NewDecoder(io.LimitReader(response.Body, 64<<10)).Decode(result); err != nil {
		return fmt.Errorf("解析 Tailcat 状态：%w", err)
	}
	return nil
}

func resolveTailcatSidecarBinary(configured string) (string, error) {
	if value := strings.TrimSpace(configured); value != "" {
		if path, err := exec.LookPath(value); err == nil {
			return path, nil
		}
		return "", fmt.Errorf("找不到 Tailcat sidecar：%s", value)
	}
	if value := strings.TrimSpace(os.Getenv("AGENTD_TAILCAT_BIN")); value != "" {
		if path, err := exec.LookPath(value); err == nil {
			return path, nil
		}
		return "", fmt.Errorf("AGENTD_TAILCAT_BIN 不可执行：%s", value)
	}
	name := tailcatSidecarBinary
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	if executable, err := os.Executable(); err == nil {
		candidate := filepath.Join(filepath.Dir(executable), name)
		if info, statErr := os.Stat(candidate); statErr == nil && !info.IsDir() {
			return candidate, nil
		}
	}
	if path, err := exec.LookPath(name); err == nil {
		return path, nil
	}
	return "", fmt.Errorf("未安装 %s；Tailcat 实验保持关闭", name)
}

func tailcatLoopbackTarget(listen string) string {
	_, rawPort, err := net.SplitHostPort(strings.TrimSpace(listen))
	if err != nil || rawPort == "" {
		rawPort = strconv.Itoa(defaultTailcatPort)
	}
	return net.JoinHostPort("127.0.0.1", rawPort)
}

func tailcatTargetPort(target string) int {
	_, rawPort, err := net.SplitHostPort(target)
	if err != nil {
		return defaultTailcatPort
	}
	port, err := strconv.Atoi(rawPort)
	if err != nil || port < 1 || port > 65535 {
		return defaultTailcatPort
	}
	return port
}

func tailcatStateDirectory(configPath string) (string, error) {
	value := strings.TrimSpace(configPath)
	if value == "" {
		return "", errors.New("Tailcat 缺少配置文件路径")
	}
	absolute, err := filepath.Abs(value)
	if err != nil {
		return "", err
	}
	return filepath.Join(filepath.Dir(absolute), "tailcat"), nil
}

func ensureTailcatLocalControlToken(stateDir string) error {
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		return fmt.Errorf("创建 Tailcat 状态目录：%w", err)
	}
	path := filepath.Join(stateDir, "local-control.token")
	if data, err := os.ReadFile(path); err == nil && strings.TrimSpace(string(data)) != "" {
		return nil
	} else if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("读取 Tailcat 本机控制凭据：%w", err)
	}
	random := make([]byte, 32)
	if _, err := rand.Read(random); err != nil {
		return fmt.Errorf("生成 Tailcat 本机控制凭据：%w", err)
	}
	return writeTailcatPrivateFile(path, []byte(hex.EncodeToString(random)+"\n"))
}

func writeTailcatPrivateFile(path string, data []byte) error {
	temporary, err := os.CreateTemp(filepath.Dir(path), ".tailcat-token-*")
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

// ReadTailcatLocalControlToken 只供同机 agentd CLI/Mac App 读取本地控制凭据。
// 该值不会进入二维码、远程 API 响应或日志。
func ReadTailcatLocalControlToken(configPath string) (string, error) {
	stateDir, err := tailcatStateDirectory(configPath)
	if err != nil {
		return "", err
	}
	data, err := os.ReadFile(filepath.Join(stateDir, "local-control.token"))
	if err != nil {
		return "", fmt.Errorf("读取 Tailcat 本机控制凭据：%w", err)
	}
	value := strings.TrimSpace(string(data))
	if value == "" {
		return "", errors.New("Tailcat 本机控制凭据为空")
	}
	return value, nil
}
