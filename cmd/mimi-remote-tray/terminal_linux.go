//go:build linux

package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

type linuxTerminalScreen struct {
	app                         *linuxTrayApplication
	page, output, pending, next string
	pair                        *linuxPairingInfo
	offset                      int
}

func runLinuxTerminal(agent, action string) error {
	if !validLinuxTerminalAction(action) {
		return errors.New("未知终端页面")
	}
	if _, err := unix.IoctlGetTermios(int(os.Stdin.Fd()), unix.TCGETS); err != nil {
		return errors.New("请在交互终端运行 mimi-remote-tray --terminal status")
	}
	controller, err := newLinuxController(agent)
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	app := &linuxTrayApplication{ctx: ctx, controller: controller, operation: make(chan struct{}, 1)}
	screen := &linuxTerminalScreen{app: app, page: "status"}
	// Use the alternate buffer so short tickets never remain in scrollback.
	fmt.Fprint(os.Stdout, "\x1b[?1049h")
	defer fmt.Fprint(os.Stdout, "\x1b[0m\x1b[?1049l")
	fmt.Fprintln(os.Stdout, "Mimi Remote · 正在读取主机状态…")
	app.refresh(false)
	screen.selectAction(action)
	lines := make(chan string)
	go scanLinuxTerminalInput(ctx, os.Stdin, lines)
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	width, height := linuxTerminalSize()
	screen.draw(os.Stdout, width, height, time.Now())
	for {
		select {
		case <-ctx.Done():
			return nil
		case input, ok := <-lines:
			if !ok || strings.EqualFold(strings.TrimSpace(input), "q") {
				return nil
			}
			fmt.Fprint(os.Stdout, "\r\x1b[2K处理中…")
			screen.input(strings.TrimSpace(input), height)
		case <-ticker.C:
			w, h := linuxTerminalSize()
			if w == width && h == height && (screen.pair == nil || !screen.expire(time.Now())) {
				continue
			}
			width, height = w, h
		}
		screen.draw(os.Stdout, width, height, time.Now())
	}
}

func scanLinuxTerminalInput(ctx context.Context, reader io.Reader, lines chan<- string) {
	defer close(lines)
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 1024), 4096)
	for scanner.Scan() {
		select {
		case lines <- scanner.Text():
		case <-ctx.Done():
			return
		}
	}
}

func linuxTerminalSize() (int, int) {
	if size, err := unix.IoctlGetWinsize(int(os.Stdout.Fd()), unix.TIOCGWINSZ); err == nil && size.Col > 0 && size.Row > 0 {
		return int(size.Col), int(size.Row)
	}
	return 100, 36
}

func (s *linuxTerminalScreen) input(input string, height int) {
	if s.pending != "" {
		pending, next := s.pending, s.next
		s.pending, s.next = "", ""
		if input != linuxConfirmationWord(pending) {
			s.output = "已取消，服务和连接保持原状。"
			return
		}
		if s.execute(pending) && next != "" {
			s.selectAction(next)
		}
		return
	}
	if input == "n" {
		s.offset += max(1, height-12)
		return
	}
	if input == "p" {
		s.offset = max(0, s.offset-max(1, height-12))
		return
	}
	if input == "r" {
		s.app.refresh(true)
		if strings.HasPrefix(s.page, "pair-") || s.page == "doctor" || s.page == "logs" {
			s.selectAction(s.page)
		} else {
			s.page = "status"
			s.output = "状态已刷新"
		}
		return
	}
	actions := map[string]string{"0": "status", "1": "pair-tailcat", "2": "pair-tailscale", "3": "pair-lan", "4": "doctor", "5": "logs", "6": "service", "s": "start", "t": "restart", "x": "stop", "e": "tailcat-enable", "d": "tailcat-disable"}
	if action, ok := actions[strings.ToLower(input)]; ok {
		s.selectAction(action)
	}
}

func linuxConfirmationWord(action string) string {
	switch action {
	case "stop":
		return "stop"
	case "restart":
		return "restart"
	case "tailcat-enable":
		return "enable"
	case "tailcat-disable":
		return "disable"
	}
	return ""
}

func (s *linuxTerminalScreen) selectAction(action string) {
	s.pending, s.next = "", ""
	s.page, s.output, s.pair, s.offset = action, "", nil, 0
	if action == "status" || action == "service" {
		return
	}
	if action == "pair-tailcat" {
		state := s.app.snapshot()
		if !state.HasTailcat || state.TailcatError != "" {
			s.output = "Tailcat 状态暂不可用。\n" + state.TailcatError
			return
		}
		if !state.Tailcat.Enabled {
			s.pending, s.next = "tailcat-enable", "pair-tailcat"
			return
		}
		if !state.Tailcat.Running {
			s.output = "Tailcat 已启用但未就绪。\n" + state.Tailcat.Error
			return
		}
	}
	if linuxConfirmationWord(action) != "" {
		s.pending = action
		return
	}
	s.execute(action)
}

func (s *linuxTerminalScreen) execute(action string) bool {
	output, pair, err := s.app.perform(action)
	s.output, s.pair, s.offset = output, pair, 0
	if err != nil {
		s.output = strings.TrimSpace(output + "\n" + err.Error())
		return false
	}
	if output == "" && pair == nil {
		s.output = "操作已完成"
	}
	return true
}

func (s *linuxTerminalScreen) expire(now time.Time) bool {
	if s.pair == nil {
		return false
	}
	expires, err := time.Parse(time.RFC3339Nano, s.pair.PairExpiresAt)
	if err == nil && expires.After(now) {
		return false
	}
	s.pair = nil
	s.output = "配对码已过期并清除。输入 r 重新生成。"
	return true
}
