package main

import "golang.org/x/sys/windows"

// net returns Winsock errors. The similarly named syscall.E* values on
// Windows are synthetic POSIX numbers and do not match them.
const (
	socketConnectionRefused   = windows.WSAECONNREFUSED
	socketAddressNotAvailable = windows.WSAEADDRNOTAVAIL
)
