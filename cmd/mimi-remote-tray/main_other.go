//go:build !windows && !linux

package main

import (
	"fmt"
	"os"
)

func main() {
	fmt.Fprintln(os.Stderr, "mimi-remote-tray 仅支持 Windows 和 Linux")
}
