//go:build !darwin

package desktopipc

import (
	"fmt"
	"net"
)

func verifyPeer(net.Conn) (DesktopInfo, error) {
	return DesktopInfo{}, fmt.Errorf("Desktop IPC is supported only on macOS")
}
