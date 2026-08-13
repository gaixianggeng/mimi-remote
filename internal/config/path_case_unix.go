//go:build !darwin && !windows

package config

func configPathCaseSensitive(string) (bool, error) { return true, nil }
