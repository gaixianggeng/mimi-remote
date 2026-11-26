//go:build !windows

package main

import "syscall"

const (
	socketConnectionRefused   = syscall.ECONNREFUSED
	socketAddressNotAvailable = syscall.EADDRNOTAVAIL
)
