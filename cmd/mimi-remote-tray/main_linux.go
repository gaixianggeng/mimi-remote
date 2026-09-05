//go:build linux

package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/godbus/dbus/v5"
)

type linuxTrayApplication struct {
	ctx        context.Context
	controller *linuxController
	notifier   *linuxNotifier
	panel      *linuxTrayPanel
	mu         sync.Mutex
	state      linuxTraySnapshot
	operation  chan struct{}
	cancel     context.CancelFunc
}

func main() {
	if len(os.Args) == 2 && (os.Args[1] == "version" || os.Args[1] == "--version") {
		fmt.Println(releaseVersion)
		return
	}
	fs := flag.NewFlagSet("mimi-remote-tray", flag.ExitOnError)
	agent := fs.String("agent", "", "agentd 的绝对路径（默认与托盘二进制同目录）")
	show := fs.Bool("show", false, "打开本机状态面板")
	quit := fs.Bool("quit", false, "退出现有托盘实例，保持 agentd 运行")
	_ = fs.Parse(os.Args[1:])
	if err := runLinuxTray(*agent, *show, *quit); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func runLinuxTray(agent string, show, quit bool) error {
	conn, err := dbus.ConnectSessionBus()
	if err != nil {
		if quit {
			return nil
		}
		return errors.New("无法连接桌面会话 D-Bus，请在登录后的 Linux 桌面启动托盘")
	}
	defer conn.Close()
	if quit {
		return quitLinuxTray(conn)
	}
	reply, err := conn.RequestName(linuxTrayBusName, dbus.NameFlagDoNotQueue)
	if err != nil {
		return err
	}
	if reply != dbus.RequestNameReplyPrimaryOwner {
		if show {
			return requestLinuxTrayControl(conn, "Show")
		}
		return nil
	}
	controller, err := newLinuxController(agent)
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	app := &linuxTrayApplication{ctx: ctx, cancel: cancel, controller: controller, operation: make(chan struct{}, 1)}
	panel, err := newLinuxTrayPanel(app)
	if err != nil {
		return err
	}
	app.panel = panel
	defer panel.close()
	notifier, err := newLinuxNotifier(conn, app.dispatch, panel.show, cancel)
	if err != nil {
		return err
	}
	app.notifier = notifier
	go notifier.watch(ctx)
	go app.refreshLoop()
	if show {
		panel.show("status")
	}
	<-ctx.Done()
	return nil
}
func (a *linuxTrayApplication) snapshot() linuxTraySnapshot {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.state
}
func (a *linuxTrayApplication) update(change func(*linuxTraySnapshot)) {
	a.mu.Lock()
	defer a.mu.Unlock()
	change(&a.state)
	if a.notifier != nil {
		a.notifier.publish(a.state)
	}
}
func (a *linuxTrayApplication) refreshLoop() {
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()
	for {
		a.refresh(false)
		select {
		case <-a.ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
func (a *linuxTrayApplication) refresh(manual bool) {
	select {
	case a.operation <- struct{}{}:
		defer func() { <-a.operation }()
	default:
		return
	}
	a.update(func(s *linuxTraySnapshot) { s.Busy = true })
	a.readStatus(manual)
	a.update(func(s *linuxTraySnapshot) { s.Busy = false })
}
func (a *linuxTrayApplication) readStatus(manual bool) error {
	ctx, cancel := context.WithTimeout(a.ctx, 35*time.Second)
	defer cancel()
	status, err := a.controller.status(ctx, manual)
	a.update(func(s *linuxTraySnapshot) {
		if err != nil {
			s.Error = redactTrayText(err.Error())
			return
		}
		s.Status = status
		s.HasStatus = true
		s.Error = ""
	})
	return err
}
func (a *linuxTrayApplication) dispatch(action string) {
	switch action {
	case "quit":
		a.cancel()
	case "refresh":
		a.refresh(true)
	case "copy":
		if err := copyLinuxEndpoint(a.ctx, a.snapshot().Status.Endpoint); err != nil {
			a.panel.show("status")
		}
	default:
		a.panel.show(action)
	}
}
func copyLinuxEndpoint(ctx context.Context, endpoint string) error {
	if endpoint == "" {
		return errors.New("连接地址尚不可用")
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	var cmd *exec.Cmd
	if os.Getenv("WAYLAND_DISPLAY") != "" {
		if path, err := exec.LookPath("wl-copy"); err == nil {
			cmd = exec.CommandContext(ctx, path, "--type", "text/plain")
		}
	} else if os.Getenv("DISPLAY") != "" {
		if path, err := exec.LookPath("xclip"); err == nil {
			cmd = exec.CommandContext(ctx, path, "-selection", "clipboard")
		}
	}
	if cmd == nil {
		return errors.New("请在状态面板复制连接地址")
	}
	cmd.Stdin = strings.NewReader(endpoint)
	cmd.WaitDelay = time.Second
	return cmd.Run()
}
func (a *linuxTrayApplication) perform(action string) (string, *linuxPairingInfo, error) {
	select {
	case a.operation <- struct{}{}:
		defer func() { <-a.operation }()
	default:
		return "", nil, errors.New("正在执行其他操作，请稍后重试")
	}
	allowed := false
	for _, item := range linuxMenuItems(a.snapshot()) {
		if item.Action == action && item.Enabled {
			allowed = true
		}
	}
	if !allowed {
		return "", nil, errors.New("当前状态下该操作不可用，请先刷新状态")
	}
	a.update(func(s *linuxTraySnapshot) { s.Busy = true })
	defer a.update(func(s *linuxTraySnapshot) { s.Busy = false })
	ctx, cancel := context.WithTimeout(a.ctx, 85*time.Second)
	defer cancel()
	if action == "pair" {
		pair, err := a.controller.pairing(ctx)
		if err != nil {
			return "", nil, err
		}
		return "", &pair, nil
	}
	if action == "refresh" {
		if err := a.readStatus(true); err != nil {
			return "", nil, err
		}
		return "状态已刷新", nil, nil
	}
	output, err := a.controller.action(ctx, action)
	if action == "start" || action == "restart" || action == "stop" {
		a.readStatus(false)
	}
	return output, nil, err
}
