package setup

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

// An uncommitted first install has no older config from which to recover its
// bearer. Keep its credentials private and durable across cancelled retries.
type interruptedIdentity struct {
	Bearer   string `json:"bearer"`
	Upstream string `json:"upstream,omitempty"`
}

func (id interruptedIdentity) digest() string {
	raw, _ := json.Marshal(id)
	return digest(raw)
}

func readInterruptedIdentity(path string) (interruptedIdentity, error) {
	var id interruptedIdentity
	b, err := config.ReadPrivateTokenFile(path, 8192)
	if errors.Is(err, os.ErrNotExist) {
		return id, nil
	}
	if err != nil {
		return id, recoveryError(path, err)
	}
	if err = json.Unmarshal(b, &id); err != nil || id.Bearer == "" {
		return interruptedIdentity{}, recoveryError(path, errors.New("无法验证保留的身份"))
	}
	return id, nil
}

func keepInterruptedIdentity(journal string, id interruptedIdentity, ops setupFileTransactionOps) error {
	path := journal + ".identity"
	previous, err := readInterruptedIdentity(path)
	if err != nil {
		return err
	}
	if previous.Bearer != "" {
		if previous != id {
			return recoveryError(path, errors.New("保留的身份不一致"))
		}
		return nil
	}
	raw, err := json.Marshal(id)
	if err != nil {
		return err
	}
	dir := filepath.Dir(path)
	stage, err := ops.stage(dir, ".mimi-identity.tmp-", raw, config.StagePermissions{Token: true})
	if err != nil {
		return err
	}
	defer ops.remove(stage)
	if err = renameNewSetupFile(stage, path); err != nil {
		return recoveryError(journal, err)
	}
	return ops.syncDir(dir)
}

func forgetCommittedIdentity(journal string, cfg config.Config, ops setupFileTransactionOps) error {
	path := journal + ".identity"
	id, err := readInterruptedIdentity(path)
	if err != nil || id.Bearer == "" {
		return err
	}
	if id.Bearer != cfg.Auth.Token {
		return recoveryError(path, errors.New("保留的身份与已提交的身份不同"))
	}
	if cfg.AppServer.Transport == "ws" && id.Upstream != "" {
		token, err := config.ReadPrivateTokenFile(config.ExpandPath(cfg.AppServer.WSTokenFile), 4096)
		if err != nil || string(bytes.TrimSpace(token)) != id.Upstream {
			return recoveryError(path, errors.New("保留的凭据与已提交的凭据不同"))
		}
	}
	if err = ops.remove(path); err != nil {
		return recoveryError(path, err)
	}
	return nil
}
