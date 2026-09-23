//go:build !darwin

package main

import (
	"errors"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func runCodexFront([]string) error {
	return errors.New("codex-front 只支持 macOS")
}

func prepareMacAppCodexFront(config.Config, string) (bool, error) { return false, nil }
