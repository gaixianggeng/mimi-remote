package httpapi

import (
	"errors"
	"fmt"
	"log"
	"maps"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sync"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/claudeenv"
	"github.com/gaixianggeng/mimi-remote/internal/debuglog"
	"github.com/gaixianggeng/mimi-remote/internal/diagnosticlog"
)

// claudeBridgeStartTimeout bounds how long we wait for a freshly spawned bridge
// to bind its socket before declaring the start failed. Overridable so tests
// can exercise the timeout path without a ten-second wait.
var claudeBridgeStartTimeout = 10 * time.Second

var errAdapterRestartRequired = errors.New("助手程序路径已变更，请在当前任务结束后重新启动 Mimi Remote 后台服务")

// residentAdapterSupervisorConfig parameterizes a resident local JSON-RPC
// adapter process (e.g. Claude SDK adapter, Antigravity ACP adapter) behind a
// Unix socket on Unix or a loopback TCP listener on Windows.
type residentAdapterSupervisorConfig struct {
	RuntimeID      string
	DisplayName    string
	TempDirPrefix  string
	DebugComponent string
	BuildEnv       func(extra map[string]string) (env []string, sensitiveValues []string)
}

func claudeResidentAdapterSupervisorConfig() residentAdapterSupervisorConfig {
	return residentAdapterSupervisorConfig{
		RuntimeID:      appServerRuntimeClaudeID,
		DisplayName:    "Claude bridge",
		TempDirPrefix:  "mimi-claude",
		DebugComponent: "claude-bridge",
		BuildEnv: func(extra map[string]string) ([]string, []string) {
			environment := buildClaudeBridgeEnv(extra)
			return environment, claudeenv.ProxyValues(environment)
		},
	}
}

type claudeBridgeSupervisor struct {
	spec       residentAdapterSupervisorConfig
	mu         sync.Mutex
	dir        string
	network    string
	address    string
	cmd        *exec.Cmd
	launchBin  string
	launchArgs []string
	launchEnv  map[string]string
	startedAt  time.Time
	done       chan struct{}
	exited     bool
	stopped    bool

	cursorMu    sync.Mutex
	cursorEpoch uint64
	cursors     map[string]uint64
	cursorFIFO  []string
}

const claudeBridgeMaxCursors = 64

func newResidentAdapterSupervisor(cfg residentAdapterSupervisorConfig) *claudeBridgeSupervisor {
	if cfg.RuntimeID == "" {
		cfg.RuntimeID = appServerRuntimeClaudeID
	}
	if cfg.DisplayName == "" {
		cfg.DisplayName = cfg.RuntimeID + " adapter"
	}
	if cfg.TempDirPrefix == "" {
		cfg.TempDirPrefix = "mimi-" + cfg.RuntimeID
	}
	if cfg.DebugComponent == "" {
		cfg.DebugComponent = cfg.RuntimeID + "-adapter"
	}
	return &claudeBridgeSupervisor{
		spec:        cfg,
		cursorEpoch: 1,
		cursors:     map[string]uint64{},
	}
}

func newClaudeBridgeSupervisor() *claudeBridgeSupervisor {
	return newResidentAdapterSupervisor(claudeResidentAdapterSupervisorConfig())
}

func (s *claudeBridgeSupervisor) specOrDefault() residentAdapterSupervisorConfig {
	if s.spec.RuntimeID == "" {
		return claudeResidentAdapterSupervisorConfig()
	}
	return s.spec
}

func (s *claudeBridgeSupervisor) noteDelivered(sessionKey string, seq uint64, epoch uint64) {
	s.cursorMu.Lock()
	defer s.cursorMu.Unlock()
	if epoch != s.cursorEpoch {
		return
	}
	if current, ok := s.cursors[sessionKey]; ok {
		if seq > current {
			s.cursors[sessionKey] = seq
		}
		return
	}
	if len(s.cursorFIFO) >= claudeBridgeMaxCursors {
		oldest := s.cursorFIFO[0]
		s.cursorFIFO = s.cursorFIFO[1:]
		delete(s.cursors, oldest)
	}
	s.cursorFIFO = append(s.cursorFIFO, sessionKey)
	s.cursors[sessionKey] = seq
}

func (s *claudeBridgeSupervisor) resumeCursor(sessionKey string) (uint64, bool) {
	s.cursorMu.Lock()
	defer s.cursorMu.Unlock()
	seq, ok := s.cursors[sessionKey]
	return seq, ok
}

func (s *claudeBridgeSupervisor) forgetCursor(sessionKey string) {
	s.cursorMu.Lock()
	defer s.cursorMu.Unlock()
	delete(s.cursors, sessionKey)
	for i, key := range s.cursorFIFO {
		if key == sessionKey {
			s.cursorFIFO = append(s.cursorFIFO[:i], s.cursorFIFO[i+1:]...)
			break
		}
	}
}

func (s *claudeBridgeSupervisor) clearCursors() {
	s.cursorMu.Lock()
	defer s.cursorMu.Unlock()
	cleared := len(s.cursors)
	s.cursorEpoch++
	s.cursors = map[string]uint64{}
	s.cursorFIFO = nil
	if cleared > 0 {
		spec := s.specOrDefault()
		log.Printf("%s cursor namespace cleared count=%d", spec.RuntimeID, cleared)
	}
}

func (s *claudeBridgeSupervisor) ensure(bin string, args []string, env map[string]string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	spec := s.specOrDefault()
	if s.stopped {
		return "", fmt.Errorf("%s 管理器已停止", spec.DisplayName)
	}
	if s.cmd != nil && !s.exited {
		if s.launchBin != bin || !slices.Equal(s.launchArgs, args) || !maps.Equal(s.launchEnv, env) {
			// Existing turns may outlive their WebSocket. Only their owner may restart the service.
			return "", errAdapterRestartRequired
		}
		return s.address, nil
	}
	if s.cmd != nil {
		log.Printf("%s exited; starting a replacement", spec.DisplayName)
		s.reset()
	}
	if err := s.start(bin, args, env); err != nil {
		s.reset()
		return "", err
	}
	return s.address, nil
}

func (s *claudeBridgeSupervisor) start(bin string, args []string, env map[string]string) error {
	spec := s.specOrDefault()
	if s.dir == "" {
		dir, err := os.MkdirTemp("", spec.TempDirPrefix)
		if err != nil {
			return fmt.Errorf("创建 %s 运行目录失败：%w", spec.DisplayName, err)
		}
		s.dir = dir
	}
	network, address, transportArgs, err := prepareClaudeBridgeEndpoint(s.dir)
	if err != nil {
		return err
	}

	cmd := exec.Command(bin, append(append([]string{}, args...), transportArgs...)...)
	var bridgeEnvironment []string
	var sensitiveValues []string
	if spec.BuildEnv != nil {
		bridgeEnvironment, sensitiveValues = spec.BuildEnv(env)
	} else {
		bridgeEnvironment = os.Environ()
	}
	cmd.Env = bridgeEnvironment
	configureGatewayCommandProcessGroup(cmd)
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return fmt.Errorf("创建 %s stderr 失败：%w", spec.DisplayName, err)
	}
	if err := startGatewayCommand(cmd); err != nil {
		return fmt.Errorf("启动 %s 失败：%w", spec.DisplayName, err)
	}
	s.startedAt = time.Now().UTC()
	debuglog.Printf(spec.DebugComponent, "started bin=%s pid=%d", filepath.Base(bin), cmd.Process.Pid)
	go captureResidentAdapterStderr(spec.DebugComponent, spec.DisplayName, stderr, sensitiveValues)

	done := make(chan struct{})
	s.launchBin, s.launchArgs, s.launchEnv = bin, slices.Clone(args), maps.Clone(env)
	s.cmd = cmd
	s.done = done
	s.network = network
	s.address = address
	s.exited = false
	go s.reap(cmd, done)

	if err := waitForResidentAdapterEndpoint(spec.DisplayName, network, address, done, claudeBridgeStartTimeout); err != nil {
		terminateGatewayProcessGroup(cmd, true)
		return err
	}
	return nil
}

func (s *claudeBridgeSupervisor) reap(cmd *exec.Cmd, done chan struct{}) {
	spec := s.specOrDefault()
	err := cmd.Wait()
	releaseGatewayProcessGroup(cmd)
	s.mu.Lock()
	if s.cmd == cmd {
		s.exited = true
	}
	s.mu.Unlock()
	if err != nil {
		log.Printf("%s exited err=%v", spec.DisplayName, err)
		diagnosticlog.Record("bridge", "failed", diagnosticlog.Fields{})
		debuglog.Printf(spec.DebugComponent, "exited pid=%d err=%v", cmd.Process.Pid, err)
	} else {
		log.Printf("%s exited", spec.DisplayName)
		diagnosticlog.Record("bridge", "stopped", diagnosticlog.Fields{})
		debuglog.Printf(spec.DebugComponent, "exited pid=%d", cmd.Process.Pid)
	}
	close(done)
}

func (s *claudeBridgeSupervisor) dial() (net.Conn, uint64, error) {
	s.mu.Lock()
	spec := s.specOrDefault()
	network := s.network
	address := s.address
	alive := s.cmd != nil && !s.exited
	s.cursorMu.Lock()
	cursorEpoch := s.cursorEpoch
	s.cursorMu.Unlock()
	s.mu.Unlock()
	if !alive || network == "" || address == "" {
		return nil, 0, fmt.Errorf("%s 未运行", spec.DisplayName)
	}
	deadline := time.Now().Add(2 * time.Second)
	for {
		conn, err := net.DialTimeout(network, address, time.Second)
		if err == nil {
			return conn, cursorEpoch, nil
		}
		if time.Now().After(deadline) {
			return nil, 0, err
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func (s *claudeBridgeSupervisor) runningSince() *time.Time {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cmd == nil || s.exited || s.startedAt.IsZero() {
		return nil
	}
	startedAt := s.startedAt
	return &startedAt
}

func (s *claudeBridgeSupervisor) shutdown() {
	s.mu.Lock()
	spec := s.specOrDefault()
	s.stopped = true
	cmd, done, exited, dir := s.cmd, s.done, s.exited, s.dir
	s.dir = ""
	s.reset()
	s.mu.Unlock()

	if cmd != nil && !exited {
		terminateResidentAdapter(spec.DisplayName, cmd, done)
	}
	if dir != "" {
		_ = os.RemoveAll(dir)
	}
}

func terminateClaudeBridge(cmd *exec.Cmd, done <-chan struct{}) {
	terminateResidentAdapter("Claude bridge", cmd, done)
}

func terminateResidentAdapter(displayName string, cmd *exec.Cmd, done <-chan struct{}) {
	terminateGatewayProcessGroup(cmd, false)
	select {
	case <-done:
		return
	case <-time.After(300 * time.Millisecond):
	}
	terminateGatewayProcessGroup(cmd, true)
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		log.Printf("%s process did not exit after SIGKILL pid=%d", displayName, gatewayProcessID(cmd))
	}
}

func (s *claudeBridgeSupervisor) reset() {
	s.cmd = nil
	s.launchBin, s.launchArgs, s.launchEnv = "", nil, nil
	s.done = nil
	s.network = ""
	s.address = ""
	s.startedAt = time.Time{}
	s.exited = false
	s.clearCursors()
}

func waitForClaudeBridgeEndpoint(network, address string, done <-chan struct{}, timeout time.Duration) error {
	return waitForResidentAdapterEndpoint("Claude bridge", network, address, done, timeout)
}

func waitForResidentAdapterEndpoint(displayName, network, address string, done <-chan struct{}, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		select {
		case <-done:
			return fmt.Errorf("%s 启动后立即退出", displayName)
		default:
		}
		if network == "unix" {
			if _, err := os.Stat(address); err == nil {
				return nil
			}
		} else {
			conn, err := net.DialTimeout(network, address, 250*time.Millisecond)
			if err == nil {
				_ = conn.Close()
				return nil
			}
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("%s 在 %s 内未监听本地端点 %s", displayName, timeout, address)
		}
		time.Sleep(25 * time.Millisecond)
	}
}
