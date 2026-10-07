//go:build darwin

package appserver

import (
	"context"
	"errors"
	"net"
	"syscall"

	"golang.org/x/sys/unix"
)

func (t *SharedLocalTransport) validateConnectionSession(ctx context.Context, conn net.Conn) error {
	pid, uid, err := sharedLocalPeerIdentity(conn)
	if err != nil {
		return newSharedLocalSessionError("peer_identity", err)
	}
	probeCtx, cancel := context.WithTimeout(ctx, sharedLocalSessionTimeout)
	defer cancel()
	dialer, err := t.rawWebSocketDialer(sharedLocalSessionTimeout)
	if err != nil {
		return err
	}
	probe, response, err := dialer.DialContext(probeCtx, sharedLocalHandshakeURL, nil)
	if response != nil && response.Body != nil {
		_ = response.Body.Close()
	}
	if err != nil {
		return sharedLocalSessionIOError(probeCtx, err)
	}
	defer probe.Close()
	stopInterrupt := context.AfterFunc(probeCtx, func() { _ = probe.Close() })
	defer stopInterrupt()
	probe.SetReadLimit(sharedLocalFrameBytesCap)
	probePID, probeUID, err := sharedLocalPeerIdentity(probe.UnderlyingConn())
	if err != nil || pid <= 0 || pid != probePID || uid != probeUID {
		return newSharedLocalSessionError("peer_changed", errors.New("登录环境探针与业务连接的 Unix peer 不一致"))
	}
	// 使用独立连接完成 initialize 和探针，保留业务连接的原始协议状态。
	// 先固定业务连接、再比对 probe 的 peer，可拒绝校验期间替换 socket 的竞态。
	initializeResult, err := initializeWebSocketResult(probeCtx, probe)
	if err != nil {
		return sharedLocalSessionIOError(probeCtx, err)
	}
	if err := validateExpectedBackendCodexHome(t.expectedBackendHome, initializeResult.CodexHome, t.requireBackendHome); err != nil {
		return err
	}
	return validateSharedLocalSession(probeCtx, probe)
}

func sharedLocalPeerIdentity(conn net.Conn) (int, uint32, error) {
	syscallConn, ok := conn.(syscall.Conn)
	if !ok {
		return 0, 0, errors.New("Unix connection 不支持原生 peer 校验")
	}
	raw, err := syscallConn.SyscallConn()
	if err != nil {
		return 0, 0, err
	}
	var pid int
	var uid uint32
	var socketErr error
	if err := raw.Control(func(fd uintptr) {
		pid, socketErr = unix.GetsockoptInt(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERPID)
		if socketErr != nil {
			return
		}
		var cred *unix.Xucred
		cred, socketErr = unix.GetsockoptXucred(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERCRED)
		if socketErr == nil {
			uid = cred.Uid
		}
	}); err != nil {
		return 0, 0, err
	}
	return pid, uid, socketErr
}
