package config

import (
	"encoding/json"
	"errors"
	"fmt"
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
	Code, RecoveryPath    string
}

func ReadPreflightSnapshot(path string) PreflightSnapshot {
	draft := defaults()
	draft.AppServer = DefaultSharedLocalAppServerConfig()
	if SupportsManagedAppServer() {
		draft.AppServer = DefaultManagedAppServerConfig()
	}
	s := PreflightSnapshot{Config: draft}
	_, err := permissionIdentity(path)
	s.Configured = !errors.Is(err, os.ErrNotExist)
	if err != nil && s.Configured {
		s.Code = PrivateFileDiagnostic(err)
		if errors.Is(err, os.ErrPermission) {
			s.Code = "config_permissions_unsafe"
		}
		return s
	}
	if _, err := CheckCompanionPermissions(path); err != nil {
		s.Code = PrivateFileDiagnostic(err)
		return s
	}
	journal := SetupJournalPath(path)
	if _, e := os.Lstat(journal + ".recovery"); !errors.Is(e, os.ErrNotExist) {
		if s.Configured {
			raw, err := ReadPrivatePreflightFile(path, 4<<20)
			if err == nil {
				_, err = CheckCredentialPermissions(raw)
			}
			if errors.Is(err, errPreflightFileNotPrivate) {
				s.Code = "config_permissions_unsafe"
				return s
			}
		}
		s.Code = "config_recovery_required"
		s.RecoveryPath = "<配置目录>/" + filepath.Base(journal)
		return s
	}
	dir := filepath.Dir(path)
	dirCode := ""
	// Find the nearest existing parent without creating even the managed config directory.
	for {
		parent, e := os.Lstat(dir)
		if errors.Is(e, os.ErrNotExist) && filepath.Dir(dir) != dir {
			dir = filepath.Dir(dir)
			continue
		}
		if e != nil || !parent.IsDir() {
			s.Code = "config_dir_unwritable"
			return s
		}
		if !directoryAccessible(dir, parent, true) {
			dirCode = "config_dir_unwritable"
		}
		break
	}
	if !s.Configured {
		s.Code = dirCode
		return s
	}
	raw, err := ReadPrivatePreflightFile(path, 4<<20)
	if err != nil {
		s.Code = "config_invalid"
		if errors.Is(err, errPreflightFileNotPrivate) {
			s.Code = "config_permissions_unsafe"
		}
		return s
	}
	s = InspectCommittedDocument(raw)
	if s.Code == "" {
		s.Code = dirCode
	}
	return s
}

// ParseSetupDocument checks persisted intent without environment overrides,
// runtime probes or project discovery. A proposed WS file may not be published yet.
func ParseSetupDocument(raw []byte) PreflightSnapshot {
	s := PreflightSnapshot{Configured: true}
	var marker struct {
		Claude struct {
			Activation string `json:"activation"`
		} `json:"claude"`
		Onboarding struct {
			WorkspaceConfirmed json.RawMessage `json:"workspace_confirmed"`
		} `json:"onboarding"`
	}
	if ValidateSetupDocumentKeys(raw) != nil || json.Unmarshal(raw, &marker) != nil || strings.TrimSpace(string(raw)) == "null" {
		s.Code = "config_invalid"
		return s
	}
	confirmed := true
	switch string(marker.Onboarding.WorkspaceConfirmed) {
	case "", "true":
	case "false":
		confirmed = false
	default:
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
	s.ClaudeActivation = marker.Claude.Activation
	s.Config = cfg
	s.Confirmed = confirmed
	return s
}

// CheckCredentialPermissions checks existing token files named in persisted bytes,
// including disabled modules and legacy transports. Missing credentials retain
// their existing module-specific diagnostics and recovery behavior.
func CheckCredentialPermissions(raw []byte) (string, error) {
	var refs struct {
		AppServer struct {
			Token string `json:"ws_token_file"`
		} `json:"app_server"`
		DeepSeek struct {
			Token string `json:"token_file"`
		} `json:"deepseek"`
	}
	// The caller handles document syntax. Opaque legacy files have no parsed references.
	// A type error in one module does not invalidate a reference decoded in the other.
	_ = json.Unmarshal(raw, &refs)
	for _, path := range []string{refs.AppServer.Token, refs.DeepSeek.Token} {
		if path == "" {
			continue
		}
		path = ExpandPath(path)
		if err := CheckPrivatePermissions(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return path, err
		}
	}
	return "", nil
}

func InspectCommittedDocument(raw []byte) PreflightSnapshot {
	s := ParseSetupDocument(raw)
	if _, err := CheckCredentialPermissions(raw); err != nil {
		s.Code = PrivateFileDiagnostic(err)
		s.Confirmed = false
		return s
	}
	if s.Code == "" && s.Config.AppServer.Transport == "ws" {
		path := ExpandPath(s.Config.AppServer.WSTokenFile)
		token, err := ReadPrivatePreflightFile(path, 4096)
		if err != nil || strings.TrimSpace(string(token)) == "" {
			s.Code = "config_recovery_required"
			if errors.Is(err, errPreflightFileNotPrivate) {
				s.Code = "config_permissions_unsafe"
			}
			s.Confirmed = false
		}
	}
	return s
}

// PrivateFileDiagnostic distinguishes repairable access from untrusted files.
func PrivateFileDiagnostic(err error) string {
	if errors.Is(err, errPreflightFileNotPrivate) {
		return "config_permissions_unsafe"
	}
	return "config_invalid"
}

var errPreflightFileNotPrivate = errors.New("文件权限不符合私有凭据要求")
var errFileNotOwned = fmt.Errorf("%w：文件不属于当前用户", errPreflightFileNotPrivate)

// ReadPrivatePreflightFile reads at most limit bytes from an existing, owned
// regular file. Check the opened file before reading, without following a
// final symlink or changing permissions.
func ReadPrivatePreflightFile(path string, limit int64) ([]byte, error) {
	expected, err := permissionIdentity(path)
	if errors.Is(err, os.ErrPermission) {
		return nil, errPreflightFileNotPrivate
	}
	if err != nil {
		return nil, err
	}
	return readPreflightFile(path, expected, limit)
}

func readPreflightFile(path string, expected os.FileInfo, limit int64) ([]byte, error) {
	if !expected.Mode().IsRegular() {
		return nil, errors.New("凭据路径必须是普通文件")
	}
	if limit < 0 || limit > 4<<20 {
		return nil, errors.New("配置文件过大")
	}
	f, err := openSnapshotFile(path)
	if errors.Is(err, os.ErrPermission) {
		// A data-read denial can itself be the permission problem. Inspect the
		// descriptor without requiring read access to credential bytes.
		if accessErr := CheckPrivatePermissions(path); accessErr != nil {
			return nil, accessErr
		}
	}
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
	if info.Size() > limit {
		return nil, errors.New("配置文件过大")
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
