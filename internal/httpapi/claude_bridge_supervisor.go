package httpapi

import (
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"os/exec"
	"sync"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/claudeenv"
)

// claudeBridgeStartTimeout bounds how long we wait for a freshly spawned bridge
// to bind its socket before declaring the start failed. Overridable so tests
// can exercise the timeout path without a ten-second wait.
var claudeBridgeStartTimeout = 10 * time.Second

// claudeBridgeSupervisor owns a single resident `alleycat-claude-bridge`
// running behind a platform-local transport: a Unix socket on Unix and a
// loopback-only TCP listener on Windows.
//
// The bridge used to be spawned per WebSocket connection, which tied every
// piece of in-flight state to the life of a phone's network link: dropping the
// connection killed the process, and with it the running turn, the Claude
// child processes and the replay ring that exists precisely to survive a
// reconnect. Keeping one process behind a socket lets a connection come and go
// while the turn keeps running.
type claudeBridgeSupervisor struct {
	mu        sync.Mutex
	dir       string
	network   string
	address   string
	cmd       *exec.Cmd
	startedAt time.Time
	// done is closed by the reaper once the process has been waited on. It is
	// the only exit signal anyone else waits for: cmd.Wait has exactly one
	// consumer, so startup and shutdown cannot starve each other of it.
	done chan struct{}
	// exited is set by the reaper once the process is gone, so the next
	// ensure() starts a replacement instead of dialing a dead socket.
	exited  bool
	stopped bool

	// cursors records, per session key, the highest sequence number this
	// supervisor instance finished relaying. It proves a client-supplied cursor
	// belongs to the current resident bridge and provides an upper bound; it is
	// not itself a client acknowledgement.
	cursorMu    sync.Mutex
	cursorEpoch uint64
	cursors     map[string]uint64
	cursorFIFO  []string
}

// claudeBridgeMaxCursors caps the resume-cursor table. Far above the handful
// of devices a single agentd serves; the bound only exists so client-chosen
// keys cannot grow the map without limit.
const claudeBridgeMaxCursors = 64

func newClaudeBridgeSupervisor() *claudeBridgeSupervisor {
	return &claudeBridgeSupervisor{
		cursorEpoch: 1,
		cursors:     map[string]uint64{},
	}
}

// noteDelivered advances the relay high-water mark for a session. Sequence
// numbers only move forward; a replayed frame must not rewind it.
func (s *claudeBridgeSupervisor) noteDelivered(sessionKey string, seq uint64, epoch uint64) {
	s.cursorMu.Lock()
	defer s.cursorMu.Unlock()
	if epoch != s.cursorEpoch {
		// 旧 bridge 连接可能在进程换代后才完成一次 WebSocket 写。它的 sequence
		// 不能重新污染刚清空的新实例 cursor namespace。
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

// forgetCursor drops a cursor the bridge told us is no longer replayable, so
// the next attach starts clean instead of asking for a sequence below the ring
// floor again.
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

// clearCursors drops every sequence watermark when the resident bridge
// process changes. Sequence numbers are scoped to one bridge instance; carrying
// them into a replacement can make a fresh ring appear fully consumed.
func (s *claudeBridgeSupervisor) clearCursors() {
	s.cursorMu.Lock()
	defer s.cursorMu.Unlock()
	cleared := len(s.cursors)
	s.cursorEpoch++
	s.cursors = map[string]uint64{}
	s.cursorFIFO = nil
	if cleared > 0 {
		log.Printf("claude bridge cursor namespace cleared count=%d", cleared)
	}
}

// ensure returns the local endpoint of a running bridge, starting one if needed.
func (s *claudeBridgeSupervisor) ensure(bin string, args []string, env map[string]string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.stopped {
		return "", errors.New("Claude bridge 管理器已停止")
	}
	if s.cmd != nil && !s.exited {
		return s.address, nil
	}
	if s.cmd != nil {
		log.Printf("claude bridge exited; starting a replacement")
		s.reset()
	}
	if err := s.start(bin, args, env); err != nil {
		s.reset()
		return "", err
	}
	return s.address, nil
}

// start spawns the bridge and blocks until its local endpoint accepts a
// connection.
// Caller must hold s.mu.
func (s *claudeBridgeSupervisor) start(bin string, args []string, env map[string]string) error {
	if s.dir == "" {
		dir, err := os.MkdirTemp("", "mimi-claude")
		if err != nil {
			return fmt.Errorf("创建 Claude bridge 运行目录失败：%w", err)
		}
		s.dir = dir
	}
	network, address, transportArgs, err := prepareClaudeBridgeEndpoint(s.dir)
	if err != nil {
		return err
	}

	cmd := exec.Command(bin, append(append([]string{}, args...), transportArgs...)...)
	bridgeEnvironment := buildClaudeBridgeEnv(env)
	cmd.Env = bridgeEnvironment
	configureGatewayCommandProcessGroup(cmd)
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return fmt.Errorf("创建 Claude bridge stderr 失败：%w", err)
	}
	if err := startGatewayCommand(cmd); err != nil {
		return fmt.Errorf("启动 Claude bridge 失败：%w", err)
	}
	s.startedAt = time.Now().UTC()
	go captureClaudeBridgeStderr(stderr, claudeenv.ProxyValues(bridgeEnvironment))

	done := make(chan struct{})
	s.cmd = cmd
	s.done = done
	s.network = network
	s.address = address
	s.exited = false
	go s.reap(cmd, done)

	if err := waitForClaudeBridgeEndpoint(network, address, done, claudeBridgeStartTimeout); err != nil {
		// Kill and walk away without waiting on the reaper: we hold s.mu, and
		// the reaper takes it before closing done, so waiting here would
		// deadlock the supervisor — and with it every later ensure() — for a
		// bridge that merely failed to bind in time. The reaper still runs and
		// still reaps; ensure() clears the bookkeeping, and the `s.cmd == cmd`
		// guard keeps this dead process from clobbering its replacement.
		terminateGatewayProcessGroup(cmd, true)
		return err
	}
	return nil
}

// reap waits on the process and marks the supervisor dirty so a later ensure()
// restarts it. It only touches shared state while cmd is still the current
// process, so a shutdown-then-restart cycle cannot have an old reaper clobber
// new state.
func (s *claudeBridgeSupervisor) reap(cmd *exec.Cmd, done chan struct{}) {
	err := cmd.Wait()
	releaseGatewayProcessGroup(cmd)
	s.mu.Lock()
	if s.cmd == cmd {
		s.exited = true
	}
	s.mu.Unlock()
	if err != nil {
		log.Printf("claude bridge exited err=%v", err)
	} else {
		log.Printf("claude bridge exited")
	}
	close(done)
}

// dial opens a connection to the resident bridge and returns the cursor epoch
// captured from the same supervisor snapshot as its socket. Each WebSocket
// connection gets its own socket connection; the bridge multiplexes them onto
// sessions.
func (s *claudeBridgeSupervisor) dial() (net.Conn, uint64, error) {
	s.mu.Lock()
	network := s.network
	address := s.address
	alive := s.cmd != nil && !s.exited
	s.cursorMu.Lock()
	cursorEpoch := s.cursorEpoch
	s.cursorMu.Unlock()
	s.mu.Unlock()
	if !alive || network == "" || address == "" {
		return nil, 0, errors.New("Claude bridge 未运行")
	}
	// reset() 也持有 s.mu，并在同一次临界区内推进 cursorEpoch。因此这里捕获
	// 到的 endpoint 与 epoch 必定属于同一个 supervisor 代次。解锁后若发生换代，
	// 最坏只会让新连接携带旧 epoch，其 delivered watermark 会被安全忽略。
	// Endpoint publication and listen readiness are not one atomic operation,
	// so a dial racing a just-started bridge can see ECONNREFUSED. Retry briefly.
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

// runningSince 返回当前 resident bridge 的真实启动时间。
// bridge 异常退出或 supervisor reset 后立即清空，避免菜单栏继续显示旧进程时长。
func (s *claudeBridgeSupervisor) runningSince() *time.Time {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cmd == nil || s.exited || s.startedAt.IsZero() {
		return nil
	}
	startedAt := s.startedAt
	return &startedAt
}

// shutdown terminates the bridge process group and removes the socket
// directory. The supervisor refuses to start again afterwards.
func (s *claudeBridgeSupervisor) shutdown() {
	s.mu.Lock()
	s.stopped = true
	cmd, done, exited, dir := s.cmd, s.done, s.exited, s.dir
	s.dir = ""
	s.reset()
	s.mu.Unlock()

	// Terminate outside the lock: the reaper takes it on its way out.
	if cmd != nil && !exited {
		// The bridge spawns Claude Code children; signal the whole group so a
		// restart does not inherit orphans still holding the workspace.
		terminateClaudeBridge(cmd, done)
	}
	if dir != "" {
		_ = os.RemoveAll(dir)
	}
}

// terminateClaudeBridge signals the whole process group, escalating to SIGKILL
// if the bridge does not go quietly. It waits on the reaper's done channel,
// which has no competing consumer.
func terminateClaudeBridge(cmd *exec.Cmd, done <-chan struct{}) {
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
		log.Printf("claude bridge process did not exit after SIGKILL pid=%d", gatewayProcessID(cmd))
	}
}

// reset clears process bookkeeping without touching s.dir, which is reused
// across restarts. Caller must hold s.mu.
func (s *claudeBridgeSupervisor) reset() {
	s.cmd = nil
	s.done = nil
	s.network = ""
	s.address = ""
	s.startedAt = time.Time{}
	s.exited = false
	s.clearCursors()
}

// waitForClaudeBridgeEndpoint polls until the bridge has bound its endpoint,
// the process dies, or the deadline passes.
//
// Unix can observe the socket node without opening a real connection. TCP has
// no equivalent readiness primitive, so the Windows path performs a loopback
// connect and immediately closes it; the bridge treats that as a harmless
// unattached local connection.
func waitForClaudeBridgeEndpoint(network, address string, done <-chan struct{}, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		select {
		case <-done:
			return errors.New("Claude bridge 启动后立即退出")
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
			return fmt.Errorf("Claude bridge 在 %s 内未监听本地端点 %s", timeout, address)
		}
		time.Sleep(25 * time.Millisecond)
	}
}
