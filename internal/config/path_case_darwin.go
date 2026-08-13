//go:build darwin

package config

import "golang.org/x/sys/unix"

const darwinPathconfCaseSensitive = 11 // _PC_CASE_SENSITIVE from sys/unistd.h

func configPathCaseSensitive(path string) (bool, error) {
	value, err := unix.Pathconf(path, darwinPathconfCaseSensitive)
	if err != nil {
		return true, err
	}
	return value != 0, nil
}
