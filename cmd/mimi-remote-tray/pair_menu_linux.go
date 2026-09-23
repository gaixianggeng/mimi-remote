//go:build linux

package main

import (
	"fmt"
	"strings"
	"time"

	qrcode "github.com/skip2/go-qrcode"
)

// Published snapshots are immutable. Only the short-lived PNG is retained;
// neither the ticket URL nor an image file is needed by the desktop host.
type linuxMenuPair struct {
	Action  string
	PNG     []byte
	Expires time.Time
	Loading bool
	Error   string
}

const linuxPairImageLabel = "用 Mimi Remote 扫码"

func linuxPairMenuItems(items []linuxMenuItem, s linuxTraySnapshot) []linuxMenuItem {
	result := make([]linuxMenuItem, 0, len(items)+4)
	for _, item := range items {
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
		if pair.Loading {
			message = "正在生成二维码…"
		} else if pair.Error != "" {
			message = pair.Error
		}
		result = append(result,
			linuxMenuItem{ID: 201, Label: message},
			linuxMenuItem{ID: 202, Label: "重新生成二维码", Action: "refresh-pair", Enabled: !s.Busy && !pair.Loading},
			linuxMenuItem{ID: 203, Label: "在终端中配对…", Action: "terminal-" + pair.Action, Enabled: !s.Busy},
		)
	}
	return result
}

func linuxPairNetworkName(action string) string {
	switch action {
	case "pair-tailcat":
		return "Tailcat"
	case "pair-tailscale":
		return "Tailscale"
	case "pair-lan":
		return "局域网"
	}
	return ""
}

func (a *linuxTrayApplication) clearMenuPair() {
	a.update(func(s *linuxTraySnapshot) {
		if a.pairTimer != nil {
			a.pairTimer.Stop()
			a.pairTimer = nil
		}
		s.PairMenu = nil
	})
}

func (a *linuxTrayApplication) toggleMenuPair(action string) {
	var request *linuxMenuPair
	a.update(func(s *linuxTraySnapshot) {
		if action == "refresh-pair" {
			if s.PairMenu == nil || s.PairMenu.Loading || s.Busy {
				return
			}
			action = s.PairMenu.Action
		} else if s.PairMenu != nil && s.PairMenu.Action == action {
			if a.pairTimer != nil {
				a.pairTimer.Stop()
			}
			s.PairMenu = nil
			return
		}
		if linuxPairNetworkName(action) == "" || s.Busy {
			return
		}
		if a.pairTimer != nil {
			a.pairTimer.Stop()
		}
		request = &linuxMenuPair{Action: action, Loading: true}
		s.PairMenu = request
	})
	if request == nil {
		return
	}
	result := &linuxMenuPair{Action: action}
	state := a.snapshot()
	if action == "pair-tailcat" && (!state.HasTailcat || state.TailcatError != "" || !state.Tailcat.Enabled || !state.Tailcat.Running) {
		result.Error = "Tailcat 尚未就绪，请在服务管理中检查"
	} else {
		_, pair, err := a.perform(action)
		if err == nil {
			result.Expires, err = time.Parse(time.RFC3339Nano, pair.PairExpiresAt)
			if err == nil && !result.Expires.After(time.Now()) {
				err = fmt.Errorf("二维码已过期，请重新生成")
			}
			if err == nil {
				var code *qrcode.QRCode
				code, err = qrcode.New(pair.PairURL, qrcode.Low)
				if err == nil {
					// Integer modules and the library's four-module quiet zone.
					result.PNG, err = code.PNG(len(code.Bitmap()) * 6)
				}
			}
		}
		if err != nil {
			result.Error = safeLinuxTerminalText(err.Error())
			result.PNG = nil
		}
	}
	a.update(func(s *linuxTraySnapshot) {
		// Closing or switching during the CLI request must not reopen a code.
		if s.PairMenu != request || a.ctx.Err() != nil {
			return
		}
		s.PairMenu = result
		if len(result.PNG) > 0 {
			a.pairTimer = time.AfterFunc(time.Until(result.Expires), func() { a.expireMenuPair(result) })
		}
	})
}

func (a *linuxTrayApplication) expireMenuPair(pair *linuxMenuPair) {
	a.update(func(s *linuxTraySnapshot) {
		if s.PairMenu == pair {
			s.PairMenu = &linuxMenuPair{Action: pair.Action, Error: "二维码已过期，请重新生成"}
		}
	})
}

func linuxTerminalPairAction(action string) string {
	return strings.TrimPrefix(action, "terminal-")
}
