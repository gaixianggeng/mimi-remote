//go:build darwin

package main

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestCodexFrontRecoveryLoadsCurrentAppAndRollsBackFailure(t *testing.T) {
	for _, mode := range []string{"success", "bootstrap failure", "socket unavailable", "cancelled"} {
		t.Run(mode, func(t *testing.T) {
			root := t.TempDir()
			contents := filepath.Join(root, "Mimi Remote Mac.app", "Contents")
			agentd := filepath.Join(contents, "Resources", "agentd")
			appMain := filepath.Join(contents, "MacOS", "Mimi Remote Mac")
			for _, path := range []string{agentd, appMain} {
				if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(path, []byte("current binary"), 0o700); err != nil {
					t.Fatal(err)
				}
			}
			install := codexFrontInstallation{Label: "test.mimi.recovery", PlistPath: filepath.Join(root, "front.plist"),
				Socket: filepath.Join(root, "public.sock"), BackendHome: filepath.Join(root, "backend")}
			oldPlist := renderCodexFrontPlist(install.Label, []string{appMain, codexFrontAppFlag}, install.Socket, "old revision", install.BackendHome)
			if err := os.WriteFile(install.PlistPath, oldPlist, 0o644); err != nil {
				t.Fatal(err)
			}
			fake := &fakeCodexFrontLaunchd{loaded: true, job: append([]byte(nil), oldPlist...)}
			if mode == "bootstrap failure" {
				fake.beforeBootstrap = func(call int, _ []byte) error {
					if call == 1 {
						return errors.New("injected failure")
					}
					return nil
				}
			}
			ops := fake.ops()
			if mode == "socket unavailable" {
				ops.socketListening = func(string) bool { return false }
			}
			reload, err := prepareCodexFrontRecovery(install, filepath.Join(root, "config.json"), agentd, ops)
			if err != nil {
				t.Fatal(err)
			}
			// 准备阶段不得断开连接或更改已经登记的前门。
			before, err := os.ReadFile(install.PlistPath)
			if err != nil || !bytes.Equal(before, oldPlist) || !fake.loaded {
				t.Fatal("准备阶段改变了服务")
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			if mode == "cancelled" {
				cancel()
			}
			err = reload(ctx)
			after, readErr := os.ReadFile(install.PlistPath)
			if readErr != nil {
				t.Fatal(readErr)
			}
			if mode == "success" {
				if err != nil || bytes.Equal(after, oldPlist) || !fake.loaded || !bytes.Equal(fake.job, after) ||
					!bytes.Contains(after, []byte(appMain)) {
					t.Fatalf("未加载当前App责任链: %v", err)
				}
			} else if err == nil || !fake.loaded || !bytes.Equal(after, oldPlist) || !bytes.Equal(fake.job, oldPlist) {
				t.Fatalf("失败或取消后必须保留原登记身份: %v", err)
			}
		})
	}
}
