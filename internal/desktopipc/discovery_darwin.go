//go:build darwin

package desktopipc

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

var desktopCommandOutput = func(ctx context.Context, name string, args ...string) ([]byte, error) {
	return exec.CommandContext(ctx, name, args...).Output()
}

func inspectDesktop(codexBin string, env map[string]string) (DesktopInfo, error) {
	bundle := desktopBundlePath(codexBin)
	if bundle == "" {
		return DesktopInfo{}, nil
	}
	infoPath := filepath.Join(bundle, "Contents", "Info.plist")
	if info, err := os.Lstat(infoPath); errors.Is(err, os.ErrNotExist) {
		return DesktopInfo{}, nil
	} else if err != nil || !info.Mode().IsRegular() {
		return DesktopInfo{}, fmt.Errorf("Desktop Info.plist is unavailable")
	}
	readPlist := func(key string) (string, error) {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		output, err := desktopCommandOutput(ctx, "/usr/bin/plutil", "-extract", key, "raw", "-o", "-", infoPath)
		if err != nil {
			return "", err
		}
		return strings.TrimSpace(string(output)), nil
	}
	bundleID, err := readPlist("CFBundleIdentifier")
	if err != nil || bundleID != "com.openai.codex" {
		return DesktopInfo{}, fmt.Errorf("installed Desktop bundle is not com.openai.codex")
	}
	version, err := readPlist("CFBundleShortVersionString")
	if err != nil {
		return DesktopInfo{}, fmt.Errorf("read Desktop version: %w", err)
	}
	build, err := readPlist("CFBundleVersion")
	if err != nil {
		return DesktopInfo{}, fmt.Errorf("read Desktop build: %w", err)
	}
	codexHome, err := resolveCodexHome(env)
	if err != nil {
		return DesktopInfo{}, err
	}
	running, err := desktopProcessRunning()
	if err != nil {
		return DesktopInfo{}, err
	}
	return DesktopInfo{
		Installed: true, Running: running, Version: version, Build: build,
		Bundle: bundle, Socket: filepath.Join(codexHome, "ipc", "ipc.sock"),
	}, nil
}

func desktopBundlePath(codexBin string) string {
	candidates := []string{strings.TrimSpace(codexBin), "/Applications/ChatGPT.app/Contents/Resources/codex"}
	if home, err := os.UserHomeDir(); err == nil {
		candidates = append(candidates, filepath.Join(home, "Applications", "ChatGPT.app", "Contents", "Resources", "codex"))
	}
	for _, candidate := range candidates {
		candidate = filepath.Clean(candidate)
		marker := ".app" + string(filepath.Separator)
		index := strings.Index(candidate, marker)
		if index < 0 {
			continue
		}
		bundle := candidate[:index+len(".app")]
		if filepath.IsAbs(bundle) {
			return bundle
		}
	}
	return ""
}

func desktopProcessRunning() (bool, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	output, err := desktopCommandOutput(ctx, "/usr/bin/lsappinfo", "find", "bundleid=com.openai.codex")
	if err != nil {
		return false, err
	}
	return strings.TrimSpace(string(output)) != "", nil
}

func desktopRunning() (bool, error) { return desktopProcessRunning() }
