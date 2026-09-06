//go:build linux

package main

import (
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
	"time"
	"unicode"

	qrcode "github.com/skip2/go-qrcode"
)

var terminalEscape = regexp.MustCompile("\x1b(?:\\[[0-?]*[ -/]*[@-~]|\\][^\x07\x1b]*(?:\x07|\x1b\\\\))")

func safeLinuxTerminalText(value string) string {
	value = terminalEscape.ReplaceAllString(value, "")
	value = strings.Map(func(r rune) rune {
		if r == '\n' || r == '\t' {
			return r
		}
		if unicode.IsControl(r) || unicode.In(r, unicode.Cf) {
			return -1
		}
		return r
	}, value)
	return redactTrayText(value)
}

func terminalCellWidth(r rune) int {
	if unicode.Is(unicode.Mn, r) {
		return 0
	}
	if unicode.In(r, unicode.Han, unicode.Hangul, unicode.Hiragana, unicode.Katakana) || r >= 0xff01 && r <= 0xff60 || r >= 0x3000 && r <= 0x303f || r >= 0x1f300 && r <= 0x1faff {
		return 2
	}
	return 1
}

func terminalClip(line string, width int) string {
	var out strings.Builder
	used := 0
	for _, r := range strings.ReplaceAll(line, "\t", "  ") {
		used += terminalCellWidth(r)
		if used > width {
			break
		}
		out.WriteRune(r)
	}
	return out.String()
}

func (s *linuxTerminalScreen) draw(w io.Writer, width, height int, now time.Time) {
	s.expire(now)
	fmt.Fprint(w, "\x1b[H\x1b[2J")
	if width < 45 || height < 15 {
		fmt.Fprint(w, "Mimi Remote\n请放大终端至至少 45 列 × 15 行。\nq + Enter 退出\n> ")
		return
	}
	accent, reset := "\x1b[1;36m", "\x1b[0m"
	if _, noColor := os.LookupEnv("NO_COLOR"); noColor {
		accent, reset = "", ""
	}
	fmt.Fprintf(w, "\n  %sMimi Remote%s  /  %s\n", accent, reset, linuxTerminalPageTitle(s.page))
	fmt.Fprintf(w, "  %s\n\n", strings.Repeat("─", min(width-4, 96)))
	if s.pair != nil {
		s.drawPair(w, width, height)
		return
	}
	content := s.content()
	rows := max(1, height-11)
	lines := strings.Split(safeLinuxTerminalText(content), "\n")
	s.offset = max(0, min(s.offset, len(lines)-rows))
	end := min(len(lines), s.offset+rows)
	for _, line := range lines[s.offset:end] {
		fmt.Fprintln(w, "  "+terminalClip(line, width-4))
	}
	if end < len(lines) || s.offset > 0 {
		fmt.Fprintf(w, "  [%d–%d / %d]  n 下一页 · p 上一页\n", s.offset+1, end, len(lines))
	}
	fmt.Fprint(w, "\n")
	if s.pending != "" {
		fmt.Fprintf(w, "  输入 %s 确认，其他输入取消。\n", linuxConfirmationWord(s.pending))
	} else {
		fmt.Fprintln(w, "  "+terminalClip("0 概览  1 Tailcat  2 Tailscale  3 局域网", width-4))
		fmt.Fprintln(w, "  "+terminalClip("4 诊断  5 日志  6 服务  r 刷新  q 退出", width-4))
	}
	fmt.Fprint(w, "\n  选择后按 Enter › ")
}

func linuxTerminalPageTitle(page string) string {
	titles := map[string]string{"status": "主机概览", "service": "服务管理", "pair-tailcat": "Tailcat · 内置连接", "pair-tailscale": "Tailscale · 外部网络", "pair-lan": "局域网配对", "doctor": "诊断", "logs": "日志", "start": "启动服务", "stop": "停止服务", "restart": "重启服务", "tailcat-enable": "启用 Tailcat", "tailcat-disable": "关闭 Tailcat"}
	return titles[page]
}

func (s *linuxTerminalScreen) content() string {
	if s.pending != "" {
		switch s.pending {
		case "tailcat-enable":
			return "Tailcat 当前未启用。\n\n启用后使用 Mimi 内置连接，无需外部 Tailscale 客户端。\n这会启动 Tailcat，并保存到当前主机配置。"
		case "tailcat-disable":
			return "关闭 Tailcat 会断开正在使用 Tailcat 的设备。\n\nagentd 和外部 Tailscale 服务继续运行。"
		case "stop":
			return "停止 Mimi Remote 服务会断开当前连接。\n\n之后可从托盘重新启动。"
		case "restart":
			return "重启 Mimi Remote 服务会暂时断开当前连接。"
		}
	}
	if s.output != "" && s.page != "status" {
		return s.output
	}
	if s.page == "service" {
		return "主机服务\n\n  s  启动\n  t  重启\n  x  停止\n\n内置连接\n\n  e  启用 Tailcat\n  d  关闭 Tailcat"
	}
	state := s.app.snapshot()
	lines := []string{"服务     " + state.title(), "Tailcat  " + state.tailcatTitle()}
	if state.HasStatus {
		if runtime := state.Status.RuntimeStatus; runtime != nil {
			for _, entry := range runtime.Runtimes {
				if entry.Enabled {
					lines = append(lines, entry.Title+"    "+linuxRuntimeLabel(entry.State))
				}
			}
		}
		lines = append(lines, "", "连接地址  "+state.Status.Endpoint)
		if network := state.Status.NetworkStatus; network != nil {
			lines = append(lines, "外部"+network.detailLines()[0])
		}
		lines = append(lines, "agentd    "+firstNonEmpty(state.Status.ServerVersion, state.Status.Version))
	}
	if state.Error != "" {
		lines = append(lines, "", "状态刷新失败："+state.Error)
	}
	if state.TailcatError != "" {
		lines = append(lines, "", "Tailcat："+state.TailcatError)
	} else if state.Tailcat.Error != "" {
		lines = append(lines, "", "Tailcat："+state.Tailcat.Error)
	}
	lines = append(lines, "", "配对方式", "  1  Tailcat     内置连接", "  2  Tailscale   外部网络", "  3  局域网      同一网络，需先启用 LAN")
	if s.output != "" {
		lines = append(lines, "", s.output)
	}
	return strings.Join(lines, "\n")
}

func (s *linuxTerminalScreen) drawPair(w io.Writer, width, height int) {
	code, err := qrcode.New(s.pair.PairURL, qrcode.Low)
	if err != nil {
		fmt.Fprint(w, "  无法生成二维码。输入 r 重试，q 退出。\n> ")
		return
	}
	bitmap := code.Bitmap() // includes the required quiet zone
	columns, rows := len(bitmap), (len(bitmap)+1)/2
	if columns+4 > width || rows+10 > height {
		fmt.Fprintf(w, "  二维码需要至少 %d 列 × %d 行。\n\n  请放大窗口或调小终端字号，二维码会自动显示。\n", columns+4, rows+10)
	} else {
		// Fixed black-on-white cells make QR contrast independent of the theme.
		for y := 0; y < len(bitmap); y += 2 {
			fmt.Fprint(w, "  \x1b[30;47m")
			for x := 0; x < len(bitmap); x++ {
				top, bottom := bitmap[y][x], y+1 < len(bitmap) && bitmap[y+1][x]
				pixel := " "
				switch {
				case top && bottom:
					pixel = "█"
				case top:
					pixel = "▀"
				case bottom:
					pixel = "▄"
				}
				fmt.Fprint(w, pixel)
			}
			fmt.Fprint(w, "\x1b[0m\n")
		}
	}
	expires, _ := time.Parse(time.RFC3339Nano, s.pair.PairExpiresAt)
	fmt.Fprintf(w, "\n  用 Mimi Remote 扫码 · 有效至 %s\n", expires.Local().Format("15:04:05"))
	fmt.Fprint(w, "  r 重新生成  0 返回概览  q 退出\n\n  选择后按 Enter › ")
}
