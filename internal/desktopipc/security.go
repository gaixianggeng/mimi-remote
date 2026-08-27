package desktopipc

import (
	"fmt"
	"net"
	"os"
)

func VerifySocket(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSocket == 0 {
		return fmt.Errorf("configured Desktop IPC path is not a socket")
	}
	if info.Mode().Perm()&0o077 != 0 {
		return fmt.Errorf("Desktop IPC socket grants group or other permissions")
	}
	uid, ok := fileOwnerUID(info.Sys())
	if !ok || uid != uint32(os.Getuid()) {
		return fmt.Errorf("Desktop IPC socket is not owned by the current user")
	}
	return nil
}

// VerifyPeer is implemented per platform. macOS validates the connected peer;
// unsupported systems reject Desktop IPC before protocol traffic starts.
func VerifyPeer(conn net.Conn) error {
	return verifyPeer(conn)
}
