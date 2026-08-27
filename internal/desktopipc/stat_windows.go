//go:build windows

package desktopipc

func fileOwnerUID(any) (uint32, bool) { return 0, false }
