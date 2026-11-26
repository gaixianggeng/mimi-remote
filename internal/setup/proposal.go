package setup

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/agybridge"
	"github.com/gaixianggeng/mimi-remote/internal/config"
)

type SaveError struct {
	Code, Step, ConfigPath, RecoveryPath string
	Cause                                error
}

func (e *SaveError) Error() string { return e.Code + ": " + e.Cause.Error() }
func (e *SaveError) Unwrap() error { return e.Cause }
func saveFailure(code string, err error) error {
	var specific *SaveError
	if errors.As(err, &specific) {
		return err
	}
	e := &SaveError{Code: code, Step: "config_store", Cause: err}
	switch code {
	case "config_invalid", "config_recovery_required", "token_rotation_requires_approval", "legacy_codex_residue":
		e.ConfigPath = "<配置目录>/config.json"
	}
	return e
}

type configImage struct {
	path   string
	raw    []byte
	exists bool
}

func readImage(path string) (configImage, error) {
	i := configImage{path: path}
	if path == "" {
		return i, nil
	}
	raw, err := config.ReadPrivatePreflightFile(path, 4<<20)
	if errors.Is(err, os.ErrNotExist) {
		return i, nil
	}
	if err != nil {
		return i, saveFailure(config.PrivateFileDiagnostic(err), err)
	}
	i.raw, i.exists = raw, true
	return i, nil
}
func (i configImage) check() error {
	now, err := readImage(i.path)
	if err != nil || i.exists != now.exists || !bytes.Equal(i.raw, now.raw) {
		return saveFailure("config_concurrent_change", errors.New("配置已被其他进程修改，请重新选择"))
	}
	return nil
}

type setupDocument map[string]json.RawMessage

// Patch only the requested leaf. RawMessage keeps unknown keys and arbitrary-precision numbers.
func (d setupDocument) spelling(key string) string {
	if _, ok := d[key]; ok || key != strings.ToLower(key) {
		return key
	}
	for k := range d {
		if strings.EqualFold(k, key) {
			return k
		}
	}
	return key
}
func (d setupDocument) set(value any, keys ...string) bool {
	k := d.spelling(keys[0])
	if len(keys) > 1 {
		var section setupDocument
		_ = json.Unmarshal(d[k], &section)
		if section == nil {
			section = setupDocument{}
		}
		if !section.set(value, keys[1:]...) {
			return false
		}
		d[k], _ = json.Marshal(section)
		return true
	}
	if value == nil {
		if _, ok := d[k]; !ok {
			return false
		}
		delete(d, k)
		return true
	}
	raw, _ := json.Marshal(value)
	var compact bytes.Buffer
	if json.Compact(&compact, d[k]) == nil && bytes.Equal(compact.Bytes(), raw) {
		return false
	}
	d[k] = raw
	return true
}

type proposal struct {
	dest, legacy, source configImage
	doc                  setupDocument
	cfg                  config.Config
	changed              bool
	companion            string
	token                []byte
	roots                []selectedDirectory
	referencedToken      configImage
}

func (p *proposal) set(value any, keys ...string) {
	if p.doc.set(value, keys...) {
		p.changed = true
	}
}

// Preview uses the same source a default-path save would consume. An explicit
// --config never inherits a different installation's grants or assistant pins.
func previewSavedSetup(path, legacy string) config.PreflightSnapshot {
	snap := config.ReadPreflightSnapshot(path)
	if snap.Code != "" || snap.Configured || legacy == "" {
		return snap
	}
	source := config.ReadPreflightSnapshot(legacy)
	if !source.Configured {
		return snap
	}
	if source.Code == "config_invalid" && config.SupportsSharedLocalAppServer() {
		if p, err := readProposal(path, legacy, false); err == nil && p.source.exists {
			raw, err := p.bytes()
			if err == nil {
				return config.ParseSetupDocument(raw)
			}
		}
	}
	return source
}

// CheckRepairSource verifies the saved identity before doctor invokes a configured
// runtime or performs a credential-preserving legacy transport migration.
func CheckRepairSource(path string) error {
	p, err := readProposal(path, "", false)
	if err == nil && !p.source.exists {
		return saveFailure("config_missing", os.ErrNotExist)
	}
	return err
}

func readProposal(path, legacy string, force bool) (*proposal, error) {
	p := &proposal{doc: setupDocument{}}
	var err error
	if journal := config.SetupJournalPath(path); filePresent(journal + ".recovery") {
		return nil, recoveryError(journal, errors.New("已保留恢复材料"))
	}
	if parent, e := os.Lstat(filepath.Dir(path)); e == nil && !parent.IsDir() {
		return nil, saveFailure("config_invalid", errors.New("配置目录不能是符号链接"))
	}
	p.dest, err = readImage(path)
	if err != nil {
		return nil, err
	}
	p.source = p.dest
	// Once a destination is committed the old install no longer supplies any field.
	if !p.dest.exists && legacy != "" {
		p.legacy, err = readImage(legacy)
		if err != nil {
			return nil, err
		}
		if p.legacy.exists {
			p.source = p.legacy
		}
	}
	if p.source.exists {
		if _, err := config.CheckCredentialPermissions(p.source.raw); err != nil {
			return nil, saveFailure(config.PrivateFileDiagnostic(err), err)
		}
		if force {
			return nil, saveFailure("token_rotation_requires_approval", errors.New("已保留现有身份"))
		}
		if err = json.Unmarshal(p.source.raw, &p.doc); err != nil || p.doc == nil {
			return nil, saveFailure("config_invalid", errors.New("配置不是有效的 JSON 对象"))
		}
		s, ws := p.parseSource()
		if s.Code != "" {
			cause := error(errors.New("已保留原配置"))
			if s.Code == "config_requires_newer_version" {
				cause = config.ErrAppServerTransportUnsupported
			}
			if s.Code == "legacy_codex_residue" {
				cause = config.ErrLegacyAppServerConfiguration
			}
			return nil, saveFailure(s.Code, cause)
		}
		p.cfg = s.Config
		if ws != "" {
			if err = p.captureToken(ws); err != nil {
				return nil, err
			}
		}
	}
	return p, nil
}

// parseSource recognizes both the native format and the historical Unix managed WS stanza.
func (p *proposal) parseSource() (config.PreflightSnapshot, string) {
	s := config.ParseSetupDocument(p.source.raw)
	// The former Unix release stored the same managed loopback WS stanza
	// that Windows still uses. Convert only that verified historical shape.
	if s.Code == "config_invalid" && config.SupportsSharedLocalAppServer() && config.ValidateSetupDocumentKeys(p.source.raw) == nil {
		var previous struct {
			AppServer config.AppServerConfig `json:"app_server"`
		}
		_ = json.Unmarshal(p.source.raw, &previous)
		ws := previous.AppServer
		if ws.Transport == "ws" && ws.Managed && ws.SSHTarget == "" && !ws.PinTransport && ws.WSTokenFile != "" && config.IsManagedLoopbackWS(ws.Listen) {
			p.set("local", "app_server", "transport")
			for _, key := range []string{"managed", "listen", "ws_token_file", "remote_gateway"} {
				p.set(nil, "app_server", key)
			}
			updated, _ := json.Marshal(p.doc)
			return config.ParseSetupDocument(updated), ws.WSTokenFile
		}
	}
	if s.Config.AppServer.Transport == "ws" {
		return s, s.Config.AppServer.WSTokenFile
	}
	return s, ""
}

// IsManagedCredential identifies only tokens belonging to a valid saved installation.
func IsManagedCredential(path string, raw []byte, target string) bool {
	p := proposal{source: configImage{raw: raw}}
	if json.Unmarshal(raw, &p.doc) != nil || p.doc == nil {
		return false
	}
	s, ws := p.parseSource()
	if s.Code != "" {
		return false
	}
	id, err := config.ConfigPathIdentity(target)
	if err != nil {
		return false
	}
	home, err := config.ConfigPathIdentity(path)
	if err != nil || filepath.Dir(id) != filepath.Dir(home) || id == home {
		return false
	}
	if ws != "" && (s.Config.AppServer.Managed || s.Config.AppServer.Transport == "local") {
		if ref, err := config.ConfigPathIdentity(ws); err == nil && ref == id {
			return true
		}
	}
	ref, err := config.ConfigPathIdentity(s.Config.DeepSeek.TokenFile)
	return err == nil && id == ref && id == managedDeepSeekTokenPath(home)
}

func (p *proposal) captureToken(path string) error {
	path = config.ExpandPath(path)
	raw, err := config.ReadPrivatePreflightFile(path, 4096)
	if err != nil || strings.TrimSpace(string(raw)) == "" {
		code := "config_recovery_required"
		if err != nil && config.PrivateFileDiagnostic(err) == "config_permissions_unsafe" {
			code = "config_permissions_unsafe"
		}
		return saveFailure(code, errors.New("无法验证配置引用的凭据"))
	}
	p.referencedToken = configImage{path: path, raw: raw, exists: true}
	return nil
}

func (p *proposal) fresh(o Options, identity interruptedIdentity) error {
	s := config.ReadPreflightSnapshot(p.dest.path)
	if s.Configured {
		return saveFailure("config_concurrent_change", errors.New("配置已出现"))
	}
	if s.Code != "" {
		return saveFailure(s.Code, errors.New("配置目录无法写入"))
	}
	cfg := s.Config
	var err error
	cfg.Auth.Token = identity.Bearer
	if cfg.Auth.Token == "" {
		cfg.Auth.Token, err = randomHex(32)
	}
	if err != nil {
		return err
	}
	cfg.Network.AllowTailscale = new(bool)
	if o.Listen != "" {
		cfg.Listen = o.Listen
		host, _, e := net.SplitHostPort(o.Listen)
		if e != nil || (o.SaveOnly && !isLoopbackHost(host)) {
			return saveFailure("invalid_request", errors.New("首次保存请选择本机监听地址"))
		}
		// An explicit legacy bind retains the corresponding legacy ingress intent.
		if !o.SaveOnly {
			cfg.Network.AllowTailscale = nil
			host, _ := splitListen(o.Listen)
			cfg.Network.AllowLAN = host == "0.0.0.0" || host == "::" || isPrivateLANIPv4(net.ParseIP(host))
		}
	}
	if o.CodexBin != "" && o.CodexBin != "auto" {
		cfg.Codex.Bin = o.CodexBin
	}
	requestedSSH := strings.TrimSpace(o.AppServerSSHTarget)
	if requestedSSH == "" {
		requestedSSH = strings.TrimSpace(os.Getenv("AGENTD_APP_SERVER_SSH_TARGET"))
	}
	if setupUsesManagedLocalAppServer(requestedSSH) {
		cfg.AppServer = config.DefaultManagedAppServerConfig()
	} else if setupUsesSharedLocalAppServer(requestedSSH) {
		cfg.AppServer = config.DefaultSharedLocalAppServerConfig()
	}
	if requestedSSH != "" {
		target, err := normalizeSetupAppServerSSHTarget(requestedSSH)
		if err != nil {
			return saveFailure("invalid_request", err)
		}
		if !config.SupportsManagedAppServer() {
			cfg.AppServer = config.AppServerConfig{Transport: "ssh", SSHTarget: target, PinTransport: true, AutoTitle: true}
		}
	}
	if cfg.AppServer.Transport == "ws" {
		suffix, err := randomHex(16)
		if err != nil {
			return err
		}
		p.companion = filepath.Join(filepath.Dir(p.dest.path), "app-server-ws-token-"+suffix)
		secret := identity.Upstream
		if secret == "" {
			secret, err = randomHex(32)
		}
		if err != nil {
			return err
		}
		p.token = []byte(secret + "\n")
		cfg.AppServer.WSTokenFile = p.companion
	}
	raw, err := json.Marshal(cfg)
	if err != nil {
		return err
	}
	if err = json.Unmarshal(raw, &p.doc); err != nil {
		return err
	}
	p.cfg = cfg
	p.changed = true
	return nil
}

var observeSetupAssistant = inspectPreflightRuntime

func (p *proposal) applyAssistants(ctx context.Context, o Options) error {
	for id, value := range o.RuntimePaths {
		if err := p.applyPin(id, value); err != nil {
			return err
		}
	}
	type observed struct {
		id      string
		enabled bool
	}
	observations := make(chan observed, 3)
	probing, stop := context.WithTimeout(ctx, 5*time.Second)
	defer stop()
	pending := map[string]bool{}
	for _, id := range []string{"codex", "claude", "agy"} {
		pref := o.Assistants[id]
		if pref == "" && p.source.exists {
			continue
		}
		if pref == "" {
			pref = "auto"
		}
		p.set(pref, id, "activation")
		if pref != "auto" {
			p.set(pref == "enabled", id, "enabled")
			continue
		}
		pending[id] = true
		cfg, override, inspect := p.cfg, o.RuntimePaths[id], observeSetupAssistant
		if o.ObserveAssistant != nil {
			inspect = o.ObserveAssistant
		}
		go func() {
			obs := inspect(probing, id, cfg, override, PreflightHost{})
			observations <- observed{id, obs.Available != nil && *obs.Available && obs.Code == ""}
		}()
	}
	for len(pending) > 0 {
		select {
		case item := <-observations:
			p.set(item.enabled, item.id, "enabled")
			delete(pending, item.id)
		case <-probing.Done():
			for id := range pending {
				p.set(false, id, "enabled")
			}
			return ctx.Err()
		}
	}
	return nil
}
func (p *proposal) applyPin(id, value string) error {
	if value != "auto" && (!filepath.IsAbs(value) || strings.TrimSpace(value) != value) {
		return saveFailure("invalid_request", errors.New("请选择程序的绝对路径"))
	}
	switch id {
	case "codex":
		if value == "auto" {
			if p.cfg.Codex.Bin == "codex" {
				// Older configs can omit the bin field entirely. They already
				// use discovery, so clearing the pin requires no write or restart.
				return nil
			}
			value = "codex"
		}
		p.set(value, "codex", "bin")
	case "claude", "agy":
		key := claudeBinaryEnvKey
		if id == "agy" {
			key = agybridge.AgyBinaryEnvKey
		}
		var pin any = value
		if value == "auto" {
			pin = nil
		}
		p.set(pin, id, "env", key)
	default:
		return saveFailure("invalid_request", errors.New("助手标识无效"))
	}
	return nil
}
func (p *proposal) bytes() ([]byte, error) {
	if !p.changed {
		return p.source.raw, nil
	}
	raw, err := json.MarshalIndent(p.doc, "", "  ")
	if err != nil {
		return nil, err
	}
	raw = append(raw, '\n')
	parsed := config.ParseSetupDocument(raw)
	if parsed.Code != "" {
		return nil, saveFailure(parsed.Code, fmt.Errorf("新的配置无效"))
	}
	if p.source.exists && parsed.Config.Auth != p.cfg.Auth {
		return nil, saveFailure("config_invalid", errors.New("配置中的身份有歧义，原配置已保留"))
	}
	return raw, nil
}

func filePresent(path string) bool { _, err := os.Lstat(path); return !errors.Is(err, os.ErrNotExist) }
