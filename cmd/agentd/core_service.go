package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os/exec"
	"strings"
	"syscall"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/doctor"
)

const guiAgentLabel = "com.gaixianggeng.mimi.mac.agentd"

var inspectCorePeer = platformCorePeer
var submitCoreAction = platformCoreAction

var errCoreStarting = errors.New("后台服务尚未就绪")

// Inspect the connected socket before sending the credential. Keep using that
// same socket for readyz so a port change cannot substitute a different owner.
// An empty owner plus nil error means the port refused the loopback connection.
func inspectCoreService(ctx context.Context, platform, endpoint, token, expectedVersion, expectedManager string) (coreServiceOwner, doctor.Results, error) {
	ctx, cancel := context.WithTimeout(ctx, 6*time.Second)
	defer cancel()
	var result doctor.Results
	u, err := url.Parse(loopbackServiceEndpoint(endpoint))
	if err != nil || u.Scheme != "http" || u.Hostname() != "127.0.0.1" || u.Port() == "" {
		return coreServiceOwner{}, result, errors.New("本机服务地址无效")
	}
	conn, err := (&net.Dialer{}).DialContext(ctx, "tcp4", u.Host)
	if errors.Is(err, syscall.ECONNREFUSED) || (platform == "windows" && errors.Is(err, syscall.Errno(10061))) {
		return coreServiceOwner{}, result, nil
	}
	if err != nil {
		return coreServiceOwner{}, result, err
	}
	defer conn.Close()
	owner, err := inspectCorePeer(ctx, platform, conn)
	if err != nil || owner.manager == "" || (expectedManager != "" && owner.manager != expectedManager) {
		return coreServiceOwner{}, result, onboardingFailure("service_port_in_use", "service_daemon", true, errors.New("无法验证本机监听器的服务归属"))
	}
	if strings.TrimSpace(token) == "" {
		return owner, result, errors.New("本机服务凭据缺失")
	}
	// A deadline also bounds peer lookup on platforms whose network policy
	// tools can be slow. Do not follow redirects or consult HTTP proxies.
	deadline, _ := ctx.Deadline()
	if err := conn.SetDeadline(deadline); err != nil {
		return owner, result, err
	}
	stop := context.AfterFunc(ctx, func() { conn.Close() })
	defer stop()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://"+u.Host+"/api/readyz", nil)
	if err != nil {
		return owner, result, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Close = true
	if err = req.Write(conn); err != nil {
		return owner, result, err
	}
	resp, err := http.ReadResponse(bufio.NewReader(io.LimitReader(conn, 256<<10)), req)
	if err != nil {
		return owner, result, err
	}
	defer resp.Body.Close()
	result, decodeErr := decodeReadyServiceResults(resp.Body, expectedVersion)
	if resp.StatusCode == http.StatusServiceUnavailable {
		return owner, result, errCoreStarting
	}
	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
		return owner, result, onboardingFailure("pair_token_mismatch", "service_daemon", true, errors.New("本机服务拒绝当前配置的凭据"))
	}
	if resp.StatusCode != http.StatusOK {
		return owner, result, fmt.Errorf("readyz HTTP %d", resp.StatusCode)
	}
	if decodeErr != nil {
		return owner, result, decodeErr
	}
	if !result.OK {
		return owner, result, errCoreStarting
	}
	return owner, result, nil
}

func manageCoreService(ctx context.Context, platform, action, endpoint, token, expectedVersion string, wait time.Duration, stdout, stderr io.Writer) error {
	owner, _, err := inspectCoreService(ctx, platform, endpoint, token, expectedVersion, "")
	// A verified owner can be in the middle of starting. Wait on it, without
	// submitting a second start. Explicit restart can also recover an old binary.
	explicitRepair := action == "restart" && owner.manager != ""
	if err != nil && !errors.Is(err, errCoreStarting) && !explicitRepair {
		return onboardingFailure("service_start_failed", "service_daemon", true, err)
	}
	if owner.manager != "" && action == "start" && err == nil {
		return nil
	}
	expected := owner
	if owner.manager == "" {
		expected, err = coldCoreOwner(ctx, platform)
		if err != nil {
			return onboardingFailure("service_start_failed", "service_daemon", true, err)
		}
	}
	if expected.pid == 0 || action == "restart" {
		if err := submitCoreAction(ctx, platform, expected.manager, action, stdout, stderr); err != nil {
			return onboardingFailure("service_start_failed", "service_daemon", true, err)
		}
	}
	if wait <= 0 {
		return nil
	}
	waiting, cancel := context.WithTimeout(ctx, wait)
	defer cancel()
	for {
		found, _, err := inspectCoreService(waiting, platform, endpoint, token, expectedVersion, expected.manager)
		// A launchd kickstart can return while the old process still answers.
		// Only the next PID can attest readiness for an explicit restart.
		previousProcess := action == "restart" && owner.pid > 0 && found == owner
		if !previousProcess {
			if err != nil && !errors.Is(err, errCoreStarting) && waiting.Err() == nil {
				return onboardingFailure("service_start_failed", "service_daemon", true, err)
			}
			if err == nil && found.manager != "" {
				return nil
			}
		}
		select {
		case <-waiting.Done():
			return onboardingFailure("service_start_timeout", "service_daemon", true, waiting.Err())
		case <-time.After(200 * time.Millisecond):
		}
	}
}

func platformCoreAction(ctx context.Context, platform, owner, action string, stdout, stderr io.Writer) error {
	ctx, cancel := context.WithTimeout(ctx, 18*time.Second)
	defer cancel()
	if platform == "darwin" && owner == "gui" {
		args := []string{"kickstart"}
		if action == "restart" {
			args = append(args, "-k")
		}
		args = append(args, launchdCoreTarget(guiAgentLabel))
		cmd := exec.CommandContext(ctx, coreLaunchctl, args...)
		cmd.WaitDelay = time.Second
		cmd.Stdout = stdout
		cmd.Stderr = stderr
		return cmd.Run()
	}
	return runManagedServiceContext(ctx, platform, action, stdout, stderr)
}
