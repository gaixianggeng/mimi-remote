//go:build linux

package main

import (
	"context"
	"errors"
	"time"
)

// Owned by the tray under a.mu. Only generic action availability and local
// messages reach DBusMenu. The URL and its expiry stay in process memory.
type linuxPairCopyRequest struct {
	menuClosed bool
}

func (a *linuxTrayApplication) clearMenuPairLocked(s *linuxTraySnapshot) {
	if a.pairExpiryCancel != nil {
		a.pairExpiryCancel()
		a.pairExpiryCancel = nil
	}
	a.pairVault.Clear()
	a.pairRequest = nil
	s.HasPairLink = false
}

func (a *linuxTrayApplication) clearMenuPair() {
	a.update(a.clearMenuPairLocked)
}

func (a *linuxTrayApplication) closeMenuPair() {
	a.update(func(s *linuxTraySnapshot) {
		if a.pairRequest != nil && !s.HasPairLink {
			// Ordinary desktop menus close on click. Finish the requested
			// clipboard delivery, then discard the ticket immediately.
			a.pairRequest.menuClosed = true
			return
		}
		a.clearMenuPairLocked(s)
	})
}

func (a *linuxTrayApplication) prepareMenuPair(action string) func() {
	request := &linuxPairCopyRequest{}
	var generation uint64
	a.update(func(s *linuxTraySnapshot) {
		a.clearMenuPairLocked(s)
		generation = a.pairVault.Begin(action)
		a.pairRequest = request
		s.UIError = ""
	})
	return func() {
		state := a.snapshot()
		if action == "pair-tailcat" && (!state.HasTailcat || state.TailcatError != "" || !state.Tailcat.Enabled || !state.Tailcat.Running) {
			a.menuPairFailed(request, "Tailcat 尚未就绪，请在服务管理中检查")
			return
		}
		_, pair, err := a.perform(action)
		if err != nil {
			// CLI output can contain parts of the ticket even on failure.
			message := "无法生成配对链接，请刷新状态后重试"
			var typed *onboardingCLIError
			if errors.As(err, &typed) && typed.Diagnostic.Trusted {
				message = formatOnboardingMessage(typed.Diagnostic.Code, typed.Diagnostic.Step, "")
			}
			a.menuPairFailed(request, message)
			return
		}
		expires, err := time.Parse(time.RFC3339Nano, pair.PairExpiresAt)
		if err != nil {
			a.menuPairFailed(request, "配对链接有效期无效，请重新生成")
			return
		}
		a.update(func(s *linuxTraySnapshot) {
			if a.pairRequest != request || a.ctx.Err() != nil {
				return
			}
			if !a.pairVault.Store(generation, action, pair.PairURL, expires) {
				a.clearMenuPairLocked(s)
				s.UIError = "配对链接已失效，请重新生成"
				return
			}
			s.HasPairLink = true
			a.copyPairLinkLocked(s)
			if request.menuClosed || !s.HasPairLink {
				a.clearMenuPairLocked(s)
				return
			}
			ctx, cancel := context.WithCancel(a.ctx)
			a.pairExpiryCancel = cancel
			go runPairingExpiryLoop(ctx, &a.pairVault, generation, a.pairTickInterval, func(string, uint64) {
				a.update(func(s *linuxTraySnapshot) {
					if a.pairRequest == request {
						a.clearMenuPairLocked(s)
					}
				})
			})
		})
	}
}

func (a *linuxTrayApplication) menuPairFailed(request *linuxPairCopyRequest, message string) {
	a.update(func(s *linuxTraySnapshot) {
		if a.pairRequest == request {
			a.clearMenuPairLocked(s)
			s.UIError = message
		}
	})
}

func (a *linuxTrayApplication) copyPairLinkLocked(s *linuxTraySnapshot) {
	pairURL, expires, ok := a.pairVault.RedeemableURL("")
	if !ok {
		s.HasPairLink = false
		s.UIError = "当前没有有效配对链接，请重新生成"
		return
	}
	copyFn := a.clipboardCopy
	if copyFn == nil {
		copyFn = copyLinuxClipboardText
	}
	ctx, cancel := context.WithTimeout(a.ctx, expires.Sub(a.pairVault.currentTime()))
	defer cancel()
	if ctx.Err() != nil || copyFn(ctx, pairURL) != nil {
		s.UIError = "无法复制配对链接，请检查剪贴板工具后重试"
		return
	}
	s.UIError = ""
}
