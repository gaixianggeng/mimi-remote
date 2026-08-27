//go:build unix

package desktopipc

import "syscall"

func fileOwnerUID(raw any) (uint32, bool) {
	stat, ok := raw.(*syscall.Stat_t)
	if !ok {
		return 0, false
	}
	return stat.Uid, true
}
