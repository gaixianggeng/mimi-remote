//go:build linux

package main

import (
	"context"
	"fmt"
	"strings"
	"time"

	qrcode "github.com/skip2/go-qrcode"
)

// Published snapshots are immutable and exported over D-Bus. They NEVER store
// the short-lived pair_url; the redeemable link stays exclusively in
// linuxTrayApplication.pairVault in process-private memory.
type linuxMenuPair struct {
	Action      string
	PNG         []byte
	Expires     time.Time
	Loading     bool
	Error       string
	CanCopyLink bool
	Copied      bool
}

const linuxPairImageLabel = "用 Mimi Remote 扫码"

func linuxPairMenuItems(items []linuxMenuItem, s linuxTraySnapshot) []linuxMenuItem {
	result := make([]linuxMenuItem, 0, len(items)+5)
	for _, item := range items {
		// Avoid duplicating the copy action when the expanded inline QR block
		// renders it directly beneath the QR code.
		if item.ID == 119 && s.PairMenu != nil {
			continue
		}
		name := linuxPairNetworkName(item.Action)
		if name == "" {
			result = append(result, item)
			continue
		}
		item.Label = "展开 " + name + " 二维码"
		pair := s.PairMenu
		if pair == nil || pair.Action != item.Action {
			result = append(result, item)
			continue
		}
		item.Label, item.Enabled = "收起 "+name+" 二维码", true
		result = append(result, item)
		if len(pair.PNG) > 0 {
			result = append(result, linuxMenuItem{ID: 200, Label: linuxPairImageLabel, IconData: pair.PNG})
		}
		message := "有效至 " + pair.Expires.Local().Format("15:04:05")
		if pair.Copied && pair.CanCopyLink {
			message = "配对链接已复制 · 有效至 " + pair.Expires.Local().Format("15:04:05")
		}
		if pair.Loading {
			message = "正在生成二维码…"
		} else if pair.Error != "" {
			message = pair.Error
		}
		result = append(result,
			linuxMenuItem{ID: 201, Label: message},
			linuxMenuItem{ID: 204, Label: "复制配对链接", Action: "copy-pair-link", Enabled: !s.Busy && !pair.Loading && pair.CanCopyLink},
			linuxMenuItem{ID: 202, Label: "重新生成二维码", Action: "refresh-pair", Enabled: !s.Busy && !pair.Loading},
			linuxMenuItem{ID: 203, Label: "在终端中配对…", Action: "terminal-" + pair.Action, Enabled: !s.Busy},
		)
	}
	return result
}

func linuxPairNetworkName(action string) string {
	switch action {
	case "pair-tailscale":
		return "Tailscale"
	case "pair-tailcat":
		return "内置连接（Tailcat）"
	case "pair-lan":
		return "同一局域网"
	}
	return ""
}

func (a *linuxTrayApplication) stopPairWatchersLocked() {
	if a.pairTimer != nil {
		a.pairTimer.Stop()
		a.pairTimer = nil
	}
	if a.pairExpiryCancel != nil {
		a.pairExpiryCancel()
		a.pairExpiryCancel = nil
	}
}

func (a *linuxTrayApplication) clearMenuPair() {
	a.update(func(s *linuxTraySnapshot) {
		a.stopPairWatchersLocked()
		a.pairVault.Clear()
		s.PairMenu = nil
		s.HasPairLink = false
	})
}

func (a *linuxTrayApplication) toggleMenuPair(action string) {
	var request *linuxMenuPair
	var generation uint64
	a.update(func(s *linuxTraySnapshot) {
		if action == "refresh-pair" {
			if s.PairMenu == nil || s.PairMenu.Loading || s.Busy {
				return
			}
			action = s.PairMenu.Action
		} else if s.PairMenu != nil && s.PairMenu.Action == action {
			a.stopPairWatchersLocked()
			a.pairVault.Clear()
			s.PairMenu = nil
			s.HasPairLink = false
			return
		}
		if linuxPairNetworkName(action) == "" || s.Busy {
			return
		}
		a.stopPairWatchersLocked()
		generation = a.pairVault.Begin(action)
		s.HasPairLink = false
		s.UIError = ""
		request = &linuxMenuPair{Action: action, Loading: true}
		s.PairMenu = request
	})
	if request == nil {
		return
	}
	result := &linuxMenuPair{Action: action}
	var issuedPairURL string
	state := a.snapshot()
	if action == "pair-tailcat" && (!state.HasTailcat || state.TailcatError != "" || !state.Tailcat.Enabled || !state.Tailcat.Running) {
		result.Error = "Tailcat 尚未就绪，请在服务管理中检查"
	} else {
		_, pair, err := a.perform(action)
		if err == nil {
			result.Expires, err = time.Parse(time.RFC3339Nano, pair.PairExpiresAt)
			if err == nil && !result.Expires.After(a.pairVault.currentTime()) {
				err = fmt.Errorf("二维码已过期，请重新生成")
			}
			if err == nil {
				var code *qrcode.QRCode
				code, err = qrcode.New(pair.PairURL, qrcode.Low)
				if err == nil {
					// Integer modules and the library's four-module quiet zone.
					result.PNG, err = code.PNG(len(code.Bitmap()) * 6)
					if err == nil {
						issuedPairURL = pair.PairURL
					}
				}
			}
		}
		if err != nil {
			result.Error = safeLinuxTerminalText(formatTrayUserError(err))
			result.PNG = nil
		}
	}
	a.update(func(s *linuxTraySnapshot) {
		// Closing or switching during the CLI request must not reopen a code or
		// store a stale pairing link in private memory.
		if s.PairMenu != request || a.ctx.Err() != nil {
			return
		}
		if len(result.PNG) > 0 && issuedPairURL != "" {
			if a.pairVault.Store(generation, action, issuedPairURL, result.Expires) {
				result.CanCopyLink = true
				s.HasPairLink = true
				a.startPairExpiryLoopLocked(result)
			} else {
				result.PNG = nil
				result.CanCopyLink = false
				result.Error = "二维码已过期，请重新生成"
				s.HasPairLink = false
			}
		} else {
			s.HasPairLink = false
		}
		s.PairMenu = result
	})
}

func (a *linuxTrayApplication) startPairExpiryLoopLocked(pair *linuxMenuPair) {
	a.stopPairWatchersLocked()
	baseCtx := a.ctx
	if baseCtx == nil {
		baseCtx = context.Background()
	}
	watchCtx, cancel := context.WithCancel(baseCtx)
	a.pairExpiryCancel = cancel
	interval := a.pairTickInterval
	if interval <= 0 {
		interval = time.Second
	}
	go runPairingExpiryLoop(watchCtx, &a.pairVault, interval, func(_ string, _ uint64) {
		a.expireMenuPair(pair)
	})
}

func (a *linuxTrayApplication) expireMenuPair(pair *linuxMenuPair) {
	a.update(func(s *linuxTraySnapshot) {
		if s.PairMenu == pair {
			a.stopPairWatchersLocked()
			a.pairVault.Clear()
			s.HasPairLink = false
			s.PairMenu = &linuxMenuPair{Action: pair.Action, Error: "二维码已过期，请重新生成"}
		}
	})
}

func linuxTerminalPairAction(action string) string {
	return strings.TrimPrefix(action, "terminal-")
}
