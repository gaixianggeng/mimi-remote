package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/cliinspect"
	"github.com/gaixianggeng/mimi-remote/internal/windowslan"
)

// Use system executables for owner evidence, independent of the caller’s PATH.
var coreLaunchctl = "/bin/launchctl"
var coreSystemctl = "/usr/bin/systemctl"

var errUnknownCoreOwner = errors.New("本机监听进程与受管服务归属不符")
var errCoreOwnerPending = errors.New("等待系统确认本机监听进程")

func launchdCoreTarget(label string) string { return fmt.Sprintf("gui/%d/%s", os.Getuid(), label) }

func launchdCoreJob(ctx context.Context, label string) (registered bool, pid int, err error) {
	target := launchdCoreTarget(label)
	out, stderr, e := cliinspect.Output(ctx, func() (*exec.Cmd, error) { return exec.CommandContext(ctx, coreLaunchctl, "print", target), nil }, 128<<10)
	if e != nil {
		if strings.Contains(strings.ToLower(string(stderr)), "could not find service") {
			return false, 0, nil
		}
		return false, 0, e
	}
	for _, line := range strings.Split(string(out), "\n") {
		// launchctl print indents nested dictionaries another level.
		if value, ok := strings.CutPrefix(line, "\tpid = "); ok {
			pid, _ = strconv.Atoi(strings.TrimSpace(value))
			break
		}
	}
	return true, pid, nil
}

// Select the manager before issuing any command, including when an existing
// job has a PID but its listener is still starting.
func coldCoreOwner(ctx context.Context, platform string) (coreServiceOwner, error) {
	switch platform {
	case "linux":
		return coreServiceOwner{manager: "systemd"}, nil
	case "windows":
		return coreServiceOwner{manager: "scheduled-task"}, nil
	case "darwin":
		inspect, cancel := context.WithTimeout(ctx, 2*time.Second)
		defer cancel()
		brew, bpid, err := launchdCoreJob(inspect, homebrewServiceLabel)
		if err != nil {
			return coreServiceOwner{}, err
		}
		gui, gpid, err := launchdCoreJob(inspect, guiAgentLabel)
		if err != nil {
			return coreServiceOwner{}, err
		}
		if brew && gui && (bpid > 0) == (gpid > 0) {
			return coreServiceOwner{}, errors.New("两个后台服务均已注册，无法确认活动归属")
		}
		if gui && bpid == 0 {
			return coreServiceOwner{manager: "gui", pid: gpid}, nil
		}
		return coreServiceOwner{manager: "homebrew", pid: bpid}, nil
	default:
		return coreServiceOwner{}, unsupportedManagedServicePlatformError(platform)
	}
}

type coreServiceOwner struct {
	manager string
	pid     int
}

func platformCorePeer(ctx context.Context, platform string, conn net.Conn) (coreServiceOwner, error) {
	local := conn.LocalAddr().(*net.TCPAddr).AddrPort()
	remote := conn.RemoteAddr().(*net.TCPAddr).AddrPort()
	switch platform {
	case "darwin":
		pid, err := darwinCoreSocketPID(ctx, remote, local)
		if err != nil {
			return coreServiceOwner{}, err
		}
		_, brew, err := launchdCoreJob(ctx, homebrewServiceLabel)
		if err != nil {
			return coreServiceOwner{}, err
		}
		if brew == pid {
			return coreServiceOwner{manager: "homebrew", pid: pid}, nil
		}
		_, gui, err := launchdCoreJob(ctx, guiAgentLabel)
		if err != nil || gui <= 0 {
			return coreServiceOwner{}, errUnknownCoreOwner
		}
		if pid == gui {
			return coreServiceOwner{manager: "gui", pid: pid}, nil
		} // Older bundles run agentd directly.
		raw, err := cliinspect.Stdout(ctx, "/bin/ps", nil, "-o", "ppid=", "-p", strconv.Itoa(pid))
		ppid, _ := strconv.Atoi(strings.TrimSpace(string(raw)))
		if err == nil && ppid == gui {
			return coreServiceOwner{manager: "gui", pid: pid}, nil
		}
	case "linux":
		raw, err := cliinspect.Stdout(ctx, coreSystemctl, nil, "--user", "show", "--property=MainPID", "--value", managedServiceUnitName)
		if err != nil {
			return coreServiceOwner{}, err
		}
		pid, _ := strconv.Atoi(strings.TrimSpace(string(raw)))
		inode, err := linuxCoreSocketInode(ctx, remote, local)
		if err != nil {
			return coreServiceOwner{}, err
		}
		if pid > 0 && linuxOwnsCoreSocket(pid, inode) {
			return coreServiceOwner{manager: "systemd", pid: pid}, nil
		}
	case "windows":
		pidPath, err := windowsManagedPIDPath()
		if err != nil {
			return coreServiceOwner{}, err
		}
		raw, err := os.ReadFile(pidPath)
		if err != nil {
			return coreServiceOwner{}, err
		}
		pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
		if err != nil || pid <= 0 {
			return coreServiceOwner{}, errUnknownCoreOwner
		}
		if windowslan.TrustedPeer(ctx, conn, pid, windowsManagedTaskName) {
			return coreServiceOwner{manager: "scheduled-task", pid: pid}, nil
		}
	}
	return coreServiceOwner{}, errUnknownCoreOwner
}

// A TCP handshake may finish just before accept publishes the server's FD.
// Retry only a pending socket identity. Once a PID/inode exists the caller
// decides ownership exactly once, without sending a byte on failure.
func waitCoreSocketIdentity[T comparable](ctx context.Context, lookup func() (T, error)) (T, error) {
	var zero T
	for attempt := 0; attempt < 4; attempt++ {
		value, err := lookup()
		if err != nil || value != zero {
			return value, err
		}
		if attempt < 3 {
			select {
			case <-ctx.Done():
				return zero, ctx.Err()
			case <-time.After(25 * time.Millisecond):
			}
		}
	}
	return zero, errCoreOwnerPending
}

func darwinCoreSocketPID(ctx context.Context, server, client netip.AddrPort) (int, error) {
	return waitCoreSocketIdentity(ctx, func() (int, error) {
		out, err := cliinspect.Stdout(ctx, "/usr/sbin/lsof", nil, "-nP", "-iTCP:"+strconv.Itoa(int(server.Port())), "-sTCP:ESTABLISHED", "-Fpn")
		if err != nil {
			return 0, err
		}
		return lsofPeerPID(string(out), server, client), nil
	})
}

func lsofPeerPID(output string, server, client netip.AddrPort) int {
	pid := 0
	for _, line := range strings.Split(output, "\n") {
		if value, ok := strings.CutPrefix(line, "p"); ok {
			pid, _ = strconv.Atoi(value)
			continue
		}
		if name, ok := strings.CutPrefix(line, "n"); ok {
			from, to, ok := strings.Cut(name, "->")
			if !ok {
				continue
			}
			a, err1 := netip.ParseAddrPort(from)
			b, err2 := netip.ParseAddrPort(to)
			if err1 == nil && err2 == nil && a.Addr().Unmap() == server.Addr().Unmap() && a.Port() == server.Port() && b.Addr().Unmap() == client.Addr().Unmap() && b.Port() == client.Port() {
				return pid
			}
		}
	}
	return 0
}

func linuxCoreSocketInode(ctx context.Context, server, client netip.AddrPort) (string, error) {
	uid := strconv.Itoa(os.Geteuid())
	return waitCoreSocketIdentity(ctx, func() (string, error) {
		// A dual-stack wildcard maps an IPv4 connection into tcp6.
		for _, table := range []string{"tcp", "tcp6"} {
			prefix := "0100007F"
			if table == "tcp6" {
				prefix = "0000000000000000FFFF00000100007F"
			}
			serverAddress := fmt.Sprintf("%s:%04X", prefix, server.Port())
			clientAddress := fmt.Sprintf("%s:%04X", prefix, client.Port())
			data, err := os.ReadFile(filepath.Join("/proc/net", table))
			if err != nil {
				if table == "tcp6" && errors.Is(err, os.ErrNotExist) {
					continue
				}
				return "", err
			}
			for _, row := range strings.Split(string(data), "\n") {
				f := strings.Fields(row)
				if len(f) <= 9 || f[1] != serverAddress || f[2] != clientAddress || f[3] != "01" {
					continue
				}
				if f[9] == "0" {
					return "", nil
				}
				if f[7] != uid {
					return "", errUnknownCoreOwner
				}
				return f[9], nil
			}
		}
		return "", nil
	})
}

func linuxOwnsCoreSocket(pid int, inode string) bool {
	dir := filepath.Join("/proc", strconv.Itoa(pid), "fd")
	files, err := os.ReadDir(dir)
	if err != nil {
		return false
	}
	for _, file := range files {
		target, _ := os.Readlink(filepath.Join(dir, file.Name()))
		if target == "socket:["+inode+"]" {
			return true
		}
	}
	return false
}
