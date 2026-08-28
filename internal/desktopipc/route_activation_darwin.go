//go:build darwin

package desktopipc

import (
	"context"
	"fmt"
	"net/url"
	"os/exec"
	"strings"
)

var desktopRouteOpen = func(ctx context.Context, target string) error {
	return exec.CommandContext(ctx, "/usr/bin/open", "-b", "com.openai.codex", target).Run()
}

func activateDesktopThreadRoute(ctx context.Context, threadID, nonce string) error {
	running, err := desktopProcessRunning()
	if err != nil {
		return err
	}
	if !running {
		return fmt.Errorf("Codex Desktop is not running")
	}
	target, err := desktopThreadRouteURL(threadID, nonce)
	if err != nil {
		return err
	}
	// 使用参数数组而不是 shell，Thread ID 和 nonce 不会参与命令解析。
	return desktopRouteOpen(ctx, target)
}

func desktopThreadRouteURL(threadID, nonce string) (string, error) {
	threadID, nonce = strings.TrimSpace(threadID), strings.TrimSpace(nonce)
	if threadID == "" || strings.ContainsAny(threadID, "/?#") {
		return "", fmt.Errorf("Desktop Thread ID is invalid")
	}
	if nonce == "" {
		return "", fmt.Errorf("Desktop follow nonce is missing")
	}
	target := url.URL{Scheme: "codex", Host: "threads", Path: "/" + threadID}
	query := target.Query()
	query.Set("mimi-follow", nonce)
	target.RawQuery = query.Encode()
	return target.String(), nil
}
