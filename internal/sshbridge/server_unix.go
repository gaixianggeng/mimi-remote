//go:build darwin || linux

package sshbridge

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

type Server struct {
	listener  *net.UnixListener
	lock      *os.File
	options   Options
	ctx       context.Context
	cancel    context.CancelFunc
	wg        sync.WaitGroup
	closeOnce sync.Once
}

// Listen 只管理 Mimi 自己的 socket。持有文件锁后才能清理失效的 socket；
// 锁文件始终保留，存活的监听器和其他文件不受影响。
func Listen(path string, options Options) (*Server, error) {
	if !filepath.IsAbs(path) || len([]byte(path)) >= 104 {
		return nil, errors.New("Mimi SSH socket 路径必须为绝对路径且短于 104 字节")
	}
	if !filepath.IsAbs(options.Shell) || !filepath.IsAbs(options.Home) {
		return nil, errors.New("Mimi SSH 缺少用户 shell 或 Home")
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	if err := requirePrivatePath(dir, true); err != nil {
		return nil, err
	}
	// resident 会跨 agentd 重启存活，不能继承这个入口的 ownership lock。
	fd, err := syscall.Open(path+".lock", syscall.O_CREAT|syscall.O_RDWR|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0o600)
	if err != nil {
		return nil, err
	}
	lock := os.NewFile(uintptr(fd), path+".lock")
	keep := false
	defer func() {
		if !keep {
			_ = lock.Close()
		}
	}()
	if err := requirePrivatePath(path+".lock", false); err != nil {
		return nil, err
	}
	if err := syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return nil, errors.New("已有 Mimi 服务持有专用 SSH 入口")
	}
	if info, err := os.Lstat(path); err == nil {
		stat, ok := info.Sys().(*syscall.Stat_t)
		if !ok || stat.Uid != uint32(os.Getuid()) || info.Mode()&os.ModeSocket == 0 {
			return nil, errors.New("Mimi SSH socket 路径被其他文件占用")
		}
		conn, dialErr := net.DialTimeout("unix", path, 250*time.Millisecond)
		if dialErr == nil {
			_ = conn.Close()
			return nil, errors.New("Mimi SSH socket 仍在使用")
		}
		if !errors.Is(dialErr, syscall.ECONNREFUSED) {
			return nil, fmt.Errorf("无法确认 Mimi SSH socket 已失效：%w", dialErr)
		}
		if err := os.Remove(path); err != nil {
			return nil, err
		}
	} else if !os.IsNotExist(err) {
		return nil, err
	}
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(path, 0o600); err != nil {
		_ = listener.Close()
		return nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	s := &Server{listener: listener, lock: lock, options: options, ctx: ctx, cancel: cancel}
	keep = true
	s.wg.Add(1)
	go s.accept()
	return s, nil
}

func requirePrivatePath(path string, directory bool) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Getuid()) || info.Mode().Perm()&0o077 != 0 ||
		(directory && !info.IsDir()) || (!directory && !info.Mode().IsRegular()) {
		return errors.New("Mimi SSH 目录和锁必须属于当前用户，且不可供其他用户访问")
	}
	return nil
}

func (s *Server) Close() error {
	s.closeOnce.Do(func() {
		s.cancel()
		_ = s.listener.Close()
		s.wg.Wait()
		_ = s.lock.Close()
	})
	return nil
}

func (s *Server) accept() {
	defer s.wg.Done()
	// 同一个 SSH 连接可能并发执行多条命令，限制命令数以避免无限创建进程。
	slots := make(chan struct{}, 32)
	for {
		conn, err := s.listener.AcceptUnix()
		if err != nil {
			return
		}
		select {
		case slots <- struct{}{}:
		default:
			_ = conn.Close()
			continue
		}
		s.wg.Add(1)
		go func() {
			defer s.wg.Done()
			defer func() { <-slots }()
			defer conn.Close()
			s.serve(conn)
		}()
	}
}

func (s *Server) serve(conn *net.UnixConn) {
	if validatePeer(conn) != nil {
		return
	}
	ctx, cancel := context.WithCancel(s.ctx)
	defer cancel()
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	kind, command, err := readFrame(conn)
	if err != nil || kind != frameCommand || strings.TrimSpace(string(command)) == "" || strings.ContainsRune(string(command), 0) {
		return
	}
	_ = conn.SetReadDeadline(time.Time{})
	w := &frameWriter{w: conn}
	cmd := exec.CommandContext(ctx, s.options.Shell, "-lc", string(command))
	cmd.Dir, cmd.Env = s.options.Home, s.options.Env
	// Desktop 的官方 bootstrap 用 nohup 将 App Server 放到后台，但不另建进程组。
	// 断线时只停止 SSH 前台命令；杀整个进程组会误杀共享的 App Server。
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return cmd.Process.Signal(syscall.SIGTERM) }
	cmd.WaitDelay = 3 * time.Second
	cmd.Stdout, cmd.Stderr = streamWriter{w, frameOutput}, streamWriter{w, frameStderr}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return
	}
	if err := cmd.Start(); err != nil {
		_ = stdin.Close()
		_ = w.send(frameStderr, []byte("Mimi 无法启动 SSH 命令\n"))
		sendExit(w, 126)
		return
	}
	readDone := make(chan struct{})
	go func() {
		defer close(readDone)
		defer stdin.Close()
		eof := false
		for {
			kind, data, err := readFrame(conn)
			if err != nil {
				cancel()
				return
			}
			switch {
			case kind == frameInput && !eof:
				if _, err := stdin.Write(data); err != nil {
					cancel()
					return
				}
			case kind == frameEOF && len(data) == 0 && !eof:
				eof = true
				_ = stdin.Close()
				// EOF 只关闭命令 stdin；仍监听 socket 断开，及时取消 proxy。
			default:
				cancel()
				return
			}
		}
	}()
	err = cmd.Wait()
	code := 0
	if err != nil {
		code = 1
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			code = exit.ExitCode()
			if status, ok := exit.Sys().(syscall.WaitStatus); ok && status.Signaled() {
				code = 128 + int(status.Signal())
			}
		}
	}
	_ = conn.SetWriteDeadline(time.Now().Add(time.Second))
	sendExit(w, code)
	_ = conn.Close()
	<-readDone
}

func sendExit(w *frameWriter, code int) {
	var data [4]byte
	binary.BigEndian.PutUint32(data[:], uint32(code))
	_ = w.send(frameExit, data[:])
}

var _ io.Closer = (*Server)(nil)
