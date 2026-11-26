//go:build !darwin

package config

func repairInaccessibleFile(_ string, openErr error) (bool, error) { return false, openErr }
