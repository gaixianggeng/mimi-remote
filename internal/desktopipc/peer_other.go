//go:build !darwin

package desktopipc

import (
	"fmt"
	"net"
)

func verifyPeer(net.Conn) error {
	return fmt.Errorf("Desktop IPC is supported only on macOS")
}
