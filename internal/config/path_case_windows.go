//go:build windows

package config

func configPathCaseSensitive(string) (bool, error) { return false, nil }
