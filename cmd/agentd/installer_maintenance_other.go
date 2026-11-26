//go:build !windows

package main

import "errors"

func runInstallerMaintenance([]string) error {
	return errors.New("安装器维护仅适用于 Windows")
}
