package config

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// PreflightSnapshot describes committed bytes, independently of process overrides.
// Invalid or untrusted bytes are never used to launch an executable or contact a host.
type PreflightSnapshot struct {
	Config                Config
	Configured, Confirmed bool
	ClaudeActivation      string
	Code                  string
}

func ReadPreflightSnapshot(path string) PreflightSnapshot {
	draft := defaults()
	draft.AppServer = DefaultSharedLocalAppServerConfig()
	if SupportsManagedAppServer() {
		draft.AppServer = DefaultManagedAppServerConfig()
	}
	s := PreflightSnapshot{Config: draft}
	info, err := os.Lstat(path)
	s.Configured = !errors.Is(err, os.ErrNotExist)
	if err != nil && s.Configured {
		s.Code = "config_invalid"
		return s
	}
	dir := filepath.Dir(path)
	// Find the nearest existing parent without creating even the managed config directory.
	for {
		parent, e := os.Lstat(dir)
		if errors.Is(e, os.ErrNotExist) && filepath.Dir(dir) != dir {
			dir = filepath.Dir(dir)
			continue
		}
		if e != nil || !parent.IsDir() || !directoryAccessible(dir, parent, true) {
			s.Code = "config_dir_unwritable"
		}
		break
	}
	if s.Code != "" || !s.Configured {
		return s
	}
	raw, err := readPreflightFile(path, info, 4<<20)
	if err != nil {
		s.Code = "config_invalid"
		if errors.Is(err, errPreflightFileNotPrivate) {
			s.Code = "config_recovery_required"
		}
		return s
	}
	var marker struct {
		Claude struct {
			Activation string `json:"activation"`
		} `json:"claude"`
		Onboarding struct {
			WorkspaceConfirmed *bool `json:"workspace_confirmed"`
		} `json:"onboarding"`
	}
	if json.Unmarshal(raw, &marker) != nil || strings.TrimSpace(string(raw)) == "null" {
		s.Code = "config_invalid"
		return s
	}
	cfg, err := parseConfigDocument(raw, false)
	if err != nil {
		s.Code = "config_invalid"
		if errors.Is(err, ErrLegacyAppServerConfiguration) {
			s.Code = "legacy_codex_residue"
		}
		return s
	}
	token := strings.TrimSpace(cfg.Auth.Token)
	if len(token) < 16 || token != cfg.Auth.Token || strings.Contains(strings.ToLower(token), "change-me") {
		s.Code = "config_recovery_required"
		return s
	}
	if err := cfg.validate(false); err != nil {
		s.Code = "config_invalid"
		if errors.Is(err, ErrAppServerTransportUnsupported) {
			s.Code = "config_requires_newer_version"
		}
		return s
	}
	if cfg.AppServer.Transport == "ws" {
		path := ExpandPath(cfg.AppServer.WSTokenFile)
		token, err := ReadPrivatePreflightFile(path, 4096)
		if err != nil || strings.TrimSpace(string(token)) == "" {
			s.Code = "config_recovery_required"
			return s
		}
	}
	s.ClaudeActivation = marker.Claude.Activation
	s.Config = cfg
	s.Confirmed = marker.Onboarding.WorkspaceConfirmed == nil || *marker.Onboarding.WorkspaceConfirmed
	return s
}

var errPreflightFileNotPrivate = errors.New("文件权限未能保护本机凭据")

// ReadPrivatePreflightFile reads at most limit bytes from an existing, owned
// regular file. Check the opened file before reading, without following a
// final symlink or changing permissions.
func ReadPrivatePreflightFile(path string, limit int64) ([]byte, error) {
	expected, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	return readPreflightFile(path, expected, limit)
}

func readPreflightFile(path string, expected os.FileInfo, limit int64) ([]byte, error) {
	if !expected.Mode().IsRegular() {
		return nil, errors.New("凭据路径必须是普通文件")
	}
	if limit < 0 || limit > 4<<20 || expected.Size() > limit {
		return nil, errors.New("配置文件过大")
	}
	f, err := openSnapshotFile(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || !os.SameFile(expected, info) {
		return nil, errors.New("配置文件已变更")
	}
	if err := checkPreflightFileAccess(f, info); err != nil {
		return nil, err
	}
	raw, err := io.ReadAll(io.LimitReader(f, limit+1))
	if int64(len(raw)) > limit {
		return nil, errors.New("配置文件过大")
	}
	return raw, err
}

// InspectWorkspaceRoot inspects only directory metadata, never its children.
func InspectWorkspaceRoot(path string) (exists bool, code string) {
	info, err := os.Stat(path)
	switch {
	case errors.Is(err, os.ErrNotExist):
		return false, "workspace_not_found"
	case err != nil:
		return false, "workspace_unreadable"
	case !info.IsDir():
		return false, "workspace_not_directory"
	case !directoryAccessible(path, info, false):
		return true, "workspace_unreadable"
	default:
		return true, ""
	}
}
