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
	ctx              context.Context
	controller       *linuxController
	notifier         *linuxNotifier
	mu               sync.Mutex
	state            linuxTraySnapshot
	operation        chan struct{}
	cancel           context.CancelFunc
	pairTimer        *time.Timer
	pairExpiryCancel context.CancelFunc
	pairTickInterval time.Duration
	pairVault        pairingLinkVault
	clipboardCopy    func(context.Context, string) error
	terminalOpener   func(string)
}

func main() {
	if len(os.Args) == 2 && (os.Args[1] == "version" || os.Args[1] == "--version") {
		fmt.Println(releaseVersion)
		return
	}
	fs := flag.NewFlagSet("mimi-remote-tray", flag.ExitOnError)
	agent := fs.String("agent", "", "agentd 的绝对路径（默认与托盘二进制同目录）")
	show := fs.Bool("show", false, "在终端中打开管理界面")
	inlineQR := fs.Bool("inline-qr", false, "在已适配的桌面托盘菜单中展开二维码")
	terminal := fs.String("terminal", "", "在当前终端中打开指定管理页面")
	quit := fs.Bool("quit", false, "退出现有托盘实例，保持 agentd 运行")
	_ = fs.Parse(os.Args[1:])
	if *terminal != "" {
		if err := runLinuxTerminal(*agent, *terminal); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	if err := runLinuxTray(*agent, *show, *quit, *inlineQR); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func runLinuxTray(agent string, show, quit bool, inlineQR ...bool) error {
	conn, err := dbus.ConnectSessionBus()
	if err != nil {
		if quit {
			return errors.New("无法连接桌面会话 D-Bus，未能确认现有托盘已退出")
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
	app.state.InlineQR = len(inlineQR) > 0 && inlineQR[0]
	defer app.clearMenuPair()
	notifier, err := newLinuxNotifier(conn, app.dispatch, app.showTerminal, cancel)
	if err != nil {
		return err
	}
	app.notifier = notifier
	go notifier.watch(ctx)
	go app.refreshLoop()
	if show {
		app.showTerminal("status")
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
			s.Error = redactTrayText(formatTrayUserError(err))
			return
		}
		s.Status = status
		s.HasStatus = true
		s.Error = ""
	})
	if err == nil {
		tailcat, tailcatErr := a.controller.tailcatStatus(ctx)
		a.update(func(s *linuxTraySnapshot) {
			s.TailcatError = ""
			if tailcatErr != nil {
				s.TailcatError = redactTrayText(formatTrayUserError(tailcatErr))
				return
			}
			s.Tailcat, s.HasTailcat = tailcat, true
		})
	}
	return err
}
func (a *linuxTrayApplication) dispatch(action string) {
	if a.snapshot().InlineQR && (strings.HasPrefix(action, "pair-") || action == "refresh-pair") {
		a.toggleMenuPair(action)
		return
	}
	switch action {
	case "quit":
		a.clearMenuPair()
		a.cancel()
	case "refresh":
		a.refresh(true)
	case "copy-pair-link", "copy":
		a.copyActivePairLink()
	case "copy-endpoint":
		a.copyEndpoint()
	case "leave-pair-page":
		a.clearMenuPair()
	default:
		// Leaving the inline pairing view for another page clears any active
		// short-lived pairing ticket immediately.
		a.clearMenuPair()
		a.showTerminal(linuxTerminalPairAction(action))
	}
}

func (a *linuxTrayApplication) copyActivePairLink() {
	pairURL, ok := a.pairVault.RedeemableURL("")
	if !ok {
		a.update(func(s *linuxTraySnapshot) {
			a.stopPairWatchersLocked()
			s.HasPairLink = false
			if s.PairMenu != nil {
				s.PairMenu.CanCopyLink = false
				if len(s.PairMenu.PNG) > 0 {
					s.PairMenu = &linuxMenuPair{Action: s.PairMenu.Action, Error: "二维码已过期，请重新生成"}
				}
			}
			s.UIError = "当前没有可复制的有效配对链接，请先重新生成二维码"
		})
		return
	}
	copyFn := a.clipboardCopy
	if copyFn == nil {
		copyFn = copyLinuxClipboardText
	}
	if err := copyFn(a.ctx, pairURL); err != nil {
		// Stay in the tray and surface a safe retry hint; NEVER open a terminal
		// and NEVER include the ticket URL in UIError, D-Bus, or logs.
		a.update(func(s *linuxTraySnapshot) {
			s.UIError = "无法复制配对链接，请检查剪贴板工具后重试"
		})
		return
	}
	a.update(func(s *linuxTraySnapshot) {
		s.UIError = ""
		if s.PairMenu != nil {
			s.PairMenu.Copied = true
		}
	})
}

func (a *linuxTrayApplication) copyEndpoint() {
	endpoint := strings.TrimSpace(a.snapshot().Status.Endpoint)
	if endpoint == "" {
		a.update(func(s *linuxTraySnapshot) {
			s.UIError = "连接地址尚不可用，请刷新状态后重试"
		})
		return
	}
	copyFn := a.clipboardCopy
	if copyFn == nil {
		copyFn = copyLinuxClipboardText
	}
	if err := copyFn(a.ctx, endpoint); err != nil {
		// Stay in the tray so the user can retry without opening a terminal.
		a.update(func(s *linuxTraySnapshot) {
			s.UIError = "无法复制连接地址，请检查剪贴板工具后重试"
		})
		return
	}
	a.update(func(s *linuxTraySnapshot) {
		s.UIError = ""
	})
}

func copyLinuxClipboardText(ctx context.Context, text string) error {
	if strings.TrimSpace(text) == "" {
		return errors.New("没有可复制的内容")
	}
	if ctx == nil {
		ctx = context.Background()
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
		} else if path, err := exec.LookPath("xsel"); err == nil {
			cmd = exec.CommandContext(ctx, path, "--clipboard", "--input")
		}
	}
	if cmd == nil {
		return errors.New("未找到剪贴板工具（wl-copy / xclip / xsel）")
	}
	// Pass content exclusively via stdin so short-lived tickets never appear in argv.
	cmd.Stdin = strings.NewReader(text)
	cmd.WaitDelay = time.Second
	return cmd.Run()
}
func linuxPerformTimeout(action string) time.Duration {
	switch {
	case action == "start" || action == "restart":
		return trayCommandTimeout("linux", action)
	case action == "pair-tailcat":
		return trayCommandTimeout("linux", "tailcat", "pair")
	case strings.HasPrefix(action, "pair-"):
		return trayCommandTimeout("linux", "pair")
	case action == "doctor":
		return trayCommandTimeout("linux", "doctor", "--fix")
	case strings.HasPrefix(action, "tailcat-"):
		return trayCommandTimeout("linux", "tailcat", strings.TrimPrefix(action, "tailcat-"))
	default:
		return trayCommandTimeout("linux", action)
	}
}

func (a *linuxTrayApplication) perform(action string) (string, *linuxPairingInfo, error) {
	select {
	case a.operation <- struct{}{}:
		defer func() { <-a.operation }()
	default:
		return "", nil, errors.New("正在执行其他操作，请稍后重试")
	}
	allowed := false
	state := a.snapshot()
	state.PairMenu = nil // A visible collapse button is not permission to create a ticket.
	for _, item := range flattenLinuxMenu(linuxMenuItems(state)) {
		if item.Action == action && item.Enabled {
			allowed = true
		}
	}
	if !allowed {
		return "", nil, errors.New("当前状态下该操作不可用，请先刷新状态")
	}
	unlock, err := lockLinuxTrayOperation()
	if err != nil {
		return "", nil, err
	}
	defer unlock()
	a.update(func(s *linuxTraySnapshot) { s.Busy = true })
	defer a.update(func(s *linuxTraySnapshot) { s.Busy = false })
	ctx, cancel := context.WithTimeout(a.ctx, linuxPerformTimeout(action))
	defer cancel()
	if strings.HasPrefix(action, "pair-") {
		pair, err := a.controller.pairing(ctx, strings.TrimPrefix(action, "pair-"))
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
	if action == "start" || action == "restart" || action == "stop" || strings.HasPrefix(action, "tailcat-") {
		a.readStatus(false)
	}
	return output, nil, err
}

func (a *linuxTrayApplication) showTerminal(action string) {
	if a.terminalOpener != nil {
		a.terminalOpener(action)
		return
	}
	if err := launchLinuxTerminal(a.controller.agentPath, action); err != nil {
		a.update(func(s *linuxTraySnapshot) { s.UIError = redactTrayText(err.Error()) })
		fmt.Fprintln(os.Stderr, redactTrayText(err.Error()))
	} else {
		a.update(func(s *linuxTraySnapshot) { s.UIError = "" })
	}
}
