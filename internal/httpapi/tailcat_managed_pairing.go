package httpapi

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
)

const (
	defaultManagedConnectionAPIBaseURL = "https://api.code89757.com"
	defaultManagedPolicySyncInterval   = 5 * time.Minute
	defaultManagedPolicyOfflineTTL     = 24 * time.Hour
	managedPairingStateFileName        = "managed-policy.json"
)

type managedPairingService interface {
	Start()
	Sync(context.Context) error
	Complete(context.Context, string, string, string) (tailcatStatus, error)
	Reset(context.Context) error
	Close()
}

type managedPairingState struct {
	Version              int      `json:"version"`
	HostID               string   `json:"host_id,omitempty"`
	HostDeviceToken      string   `json:"host_device_token,omitempty"`
	MacTailcatPublicKey  string   `json:"mac_tailcat_public_key,omitempty"`
	PolicyVersion        uint64   `json:"policy_version,omitempty"`
	PolicyFetchedAt      string   `json:"policy_fetched_at,omitempty"`
	PolicyValidUntil     string   `json:"policy_valid_until,omitempty"`
	AllowedMobileKeys    []string `json:"allowed_mobile_tailcat_public_keys,omitempty"`
	AuthorizationInvalid bool     `json:"authorization_invalid,omitempty"`
}

type managedPairingControllerOptions struct {
	BaseURL        string
	StatePath      string
	InstallationID string
	Tailcat        tailcatSidecar
	HTTPClient     *http.Client
	Now            func() time.Time
	SyncInterval   time.Duration
	OfflineTTL     time.Duration
	Random         io.Reader
	WriteState     func(string, managedPairingState) error
}

type managedPairingController struct {
	operationMu sync.Mutex
	startOnce   sync.Once
	closeOnce   sync.Once
	wait        sync.WaitGroup
	loopContext context.Context
	cancel      context.CancelFunc

	baseURL        *url.URL
	statePath      string
	installationID string
	tailcat        tailcatSidecar
	httpClient     *http.Client
	now            func() time.Time
	syncInterval   time.Duration
	offlineTTL     time.Duration
	random         io.Reader
	writeState     func(string, managedPairingState) error

	state             managedPairingState
	stateLoadError    error
	appliedKeys       []string
	appliedHostKey    string
	appliedInstanceID string
	hasApplied        bool
}

type managedPairingCompleteResponse struct {
	Host struct {
		ID string `json:"id"`
	} `json:"host"`
}

type managedHostPolicyResponse struct {
	HostID            string   `json:"hostId"`
	PolicyVersion     uint64   `json:"policyVersion"`
	ValidUntil        string   `json:"validUntil"`
	AllowedMobileKeys []string `json:"allowedMobileTailcatPublicKeys"`
}

type managedCloudError struct {
	StatusCode int
	Code       string
	Message    string
}

func (e *managedCloudError) Error() string {
	if strings.TrimSpace(e.Message) != "" {
		return e.Message
	}
	if strings.TrimSpace(e.Code) != "" {
		return e.Code
	}
	return fmt.Sprintf("托管连接服务返回 HTTP %d", e.StatusCode)
}

func newDefaultManagedPairingController(
	configPath string,
	installationID string,
	tailcat tailcatSidecar,
) *managedPairingController {
	stateDir, err := tailcatStateDirectory(configPath)
	if err != nil || strings.TrimSpace(installationID) == "" || tailcat == nil {
		return nil
	}
	controller, err := newManagedPairingController(managedPairingControllerOptions{
		BaseURL:        defaultManagedConnectionAPIBaseURL,
		StatePath:      filepath.Join(stateDir, managedPairingStateFileName),
		InstallationID: installationID,
		Tailcat:        tailcat,
	})
	if err != nil {
		return nil
	}
	return controller
}

func newManagedPairingController(options managedPairingControllerOptions) (*managedPairingController, error) {
	baseURL, err := parseManagedConnectionBaseURL(options.BaseURL)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(options.StatePath) == "" || options.Tailcat == nil {
		return nil, errors.New("托管连接缺少本地状态路径或 Tailcat 管理器")
	}
	if parsed, err := uuid.Parse(strings.TrimSpace(options.InstallationID)); err != nil || parsed.Version() != 4 {
		return nil, errors.New("托管连接缺少有效的 Mac 安装身份")
	}
	loopContext, cancel := context.WithCancel(context.Background())
	controller := &managedPairingController{
		baseURL:        baseURL,
		statePath:      options.StatePath,
		installationID: strings.ToLower(strings.TrimSpace(options.InstallationID)),
		tailcat:        options.Tailcat,
		httpClient:     options.HTTPClient,
		now:            options.Now,
		syncInterval:   options.SyncInterval,
		offlineTTL:     options.OfflineTTL,
		random:         options.Random,
		writeState:     options.WriteState,
		loopContext:    loopContext,
		cancel:         cancel,
	}
	if controller.httpClient == nil {
		controller.httpClient = &http.Client{Timeout: 8 * time.Second}
	}
	if controller.now == nil {
		controller.now = func() time.Time { return time.Now().UTC() }
	}
	if controller.syncInterval <= 0 {
		controller.syncInterval = defaultManagedPolicySyncInterval
	}
	if controller.offlineTTL <= 0 {
		controller.offlineTTL = defaultManagedPolicyOfflineTTL
	}
	if controller.random == nil {
		controller.random = rand.Reader
	}
	if controller.writeState == nil {
		controller.writeState = writeManagedPairingState
	}
	controller.state, controller.stateLoadError = loadManagedPairingState(controller.statePath)
	return controller, nil
}

func parseManagedConnectionBaseURL(raw string) (*url.URL, error) {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || parsed.Host == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return nil, errors.New("托管连接服务地址无效")
	}
	if !strings.EqualFold(parsed.Scheme, "https") {
		host, _, splitErr := net.SplitHostPort(parsed.Host)
		if splitErr != nil {
			host = parsed.Host
		}
		ip := net.ParseIP(strings.Trim(host, "[]"))
		if !strings.EqualFold(parsed.Scheme, "http") || !(strings.EqualFold(host, "localhost") || ip != nil && ip.IsLoopback()) {
			return nil, errors.New("托管连接服务只允许 HTTPS 或本机测试地址")
		}
	}
	parsed.Path = strings.TrimRight(parsed.Path, "/")
	return parsed, nil
}

func (c *managedPairingController) Start() {
	if c == nil {
		return
	}
	c.startOnce.Do(func() {
		c.wait.Add(1)
		go c.syncLoop(c.loopContext)
	})
}

func (c *managedPairingController) syncLoop(ctx context.Context) {
	defer c.wait.Done()
	c.syncWithTimeout(ctx)
	ticker := time.NewTicker(c.syncInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			c.syncWithTimeout(ctx)
		}
	}
}

func (c *managedPairingController) syncWithTimeout(parent context.Context) {
	ctx, cancel := context.WithTimeout(parent, 10*time.Second)
	defer cancel()
	_ = c.Sync(ctx)
}

func (c *managedPairingController) Close() {
	if c == nil {
		return
	}
	c.closeOnce.Do(func() {
		c.cancel()
		c.wait.Wait()
	})
}

func (c *managedPairingController) Sync(ctx context.Context) error {
	if c == nil {
		return nil
	}
	c.operationMu.Lock()
	defer c.operationMu.Unlock()
	if c.stateLoadError != nil {
		return c.stateLoadError
	}
	if strings.TrimSpace(c.state.HostID) == "" {
		return nil
	}
	status := c.tailcat.Status(ctx)
	if !status.Running || strings.TrimSpace(status.PublicKey) == "" {
		return errors.New("Tailcat 稳定连接尚未就绪")
	}
	if c.state.MacTailcatPublicKey != status.PublicKey {
		return c.clearIdentityMismatchLocked(ctx)
	}
	_, err := c.refreshPolicyLocked(ctx)
	return err
}

func (c *managedPairingController) Complete(
	ctx context.Context,
	sessionID string,
	grant string,
	mobilePublicKey string,
) (tailcatStatus, error) {
	if c == nil {
		return tailcatStatus{}, errors.New("Mimi 托管连接尚未初始化")
	}
	parsedSession, err := uuid.Parse(strings.TrimSpace(sessionID))
	if err != nil || parsedSession.Version() != 4 {
		return tailcatStatus{}, errors.New("托管配对会话无效")
	}
	if _, err := decodeManagedDeviceToken(grant); err != nil {
		return tailcatStatus{}, errors.New("托管配对授权无效")
	}
	mobilePublicKey = strings.TrimSpace(mobilePublicKey)
	if !validManagedTailcatPublicKey(mobilePublicKey) {
		return tailcatStatus{}, errors.New("Tailcat 客户端公钥无效")
	}

	c.operationMu.Lock()
	defer c.operationMu.Unlock()
	if c.stateLoadError != nil {
		return tailcatStatus{}, c.stateLoadError
	}
	status := c.tailcat.Status(ctx)
	if !status.Running || status.Address == "" || !validManagedTailcatPublicKey(status.PublicKey) {
		return tailcatStatus{}, errors.New("Tailcat 稳定连接尚未就绪")
	}
	if c.state.MacTailcatPublicKey != "" && c.state.MacTailcatPublicKey != status.PublicKey {
		if err := c.clearRegistrationLocked(ctx); err != nil {
			return tailcatStatus{}, err
		}
	}
	if c.state.HostDeviceToken == "" {
		if err := c.rotateHostTokenLocked(); err != nil {
			return tailcatStatus{}, err
		}
	}

	complete, err := c.completeCloudPairing(ctx, parsedSession.String(), grant, status.PublicKey)
	if isManagedCloudCode(err, "host_token_conflict") {
		// Mac 被用户撤销后，控制面要求用新 Token 重新登记。只在显式新配对中
		// 轮换一次；后台同步永远不会自行替换设备凭证。
		if _, clearErr := c.applyPolicyLocked(ctx, nil); clearErr != nil {
			return tailcatStatus{}, clearErr
		}
		if rotateErr := c.rotateHostTokenLocked(); rotateErr != nil {
			return tailcatStatus{}, rotateErr
		}
		complete, err = c.completeCloudPairing(ctx, parsedSession.String(), grant, status.PublicKey)
	}
	if err != nil {
		return tailcatStatus{}, err
	}
	parsedHostID, parseErr := uuid.Parse(complete.Host.ID)
	if parseErr != nil || parsedHostID.Version() != 4 {
		return tailcatStatus{}, errors.New("托管连接服务返回了无效主机身份")
	}
	hostID := parsedHostID.String()
	next := c.state
	if next.HostID != "" && next.HostID != hostID {
		c.clearPolicyInState(&next)
	}
	next.Version = 1
	next.HostID = hostID
	next.MacTailcatPublicKey = status.PublicKey
	next.AuthorizationInvalid = false
	if err := c.saveStateLocked(next); err != nil {
		return tailcatStatus{}, err
	}
	updated, err := c.refreshPolicyLocked(ctx)
	if err != nil {
		return tailcatStatus{}, err
	}
	if !containsString(c.state.AllowedMobileKeys, mobilePublicKey) {
		return tailcatStatus{}, errors.New("托管配对公钥与已授权移动设备不一致")
	}
	return updated, nil
}

func (c *managedPairingController) Reset(ctx context.Context) error {
	if c == nil {
		return nil
	}
	c.operationMu.Lock()
	defer c.operationMu.Unlock()
	return c.clearRegistrationLocked(ctx)
}

func (c *managedPairingController) completeCloudPairing(
	ctx context.Context,
	sessionID string,
	grant string,
	macPublicKey string,
) (managedPairingCompleteResponse, error) {
	payload := map[string]string{
		"macInstallationId":   c.installationID,
		"macTailcatPublicKey": macPublicKey,
		"hostDeviceToken":     c.state.HostDeviceToken,
		"managedPairingGrant": grant,
	}
	var result managedPairingCompleteResponse
	err := c.doJSON(ctx, http.MethodPost, "/v1/pairing-sessions/"+sessionID+"/complete", "", payload, &result)
	return result, err
}

func (c *managedPairingController) refreshPolicyLocked(ctx context.Context) (tailcatStatus, error) {
	var policy managedHostPolicyResponse
	err := c.doJSON(
		ctx,
		http.MethodGet,
		"/v1/hosts/"+c.state.HostID+"/policy",
		c.state.HostDeviceToken,
		nil,
		&policy,
	)
	if err != nil {
		if cloudError := (*managedCloudError)(nil); errors.As(err, &cloudError) && cloudError.StatusCode == http.StatusUnauthorized {
			return c.invalidatePolicyLocked(ctx, err)
		}
		if c.cachedPolicyFreshLocked() {
			_, applyErr := c.applyPolicyLocked(ctx, c.state.AllowedMobileKeys)
			if applyErr != nil {
				return tailcatStatus{}, applyErr
			}
			return tailcatStatus{}, err
		}
		_, applyErr := c.applyPolicyLocked(ctx, nil)
		if applyErr != nil {
			return tailcatStatus{}, applyErr
		}
		return tailcatStatus{}, err
	}
	if policy.HostID != c.state.HostID || policy.PolicyVersion == 0 {
		return c.invalidatePolicyLocked(ctx, errors.New("托管连接策略身份或版本无效"))
	}
	if c.state.PolicyVersion != 0 && policy.PolicyVersion < c.state.PolicyVersion {
		return c.invalidatePolicyLocked(ctx, errors.New("托管连接策略版本发生回退"))
	}
	validUntil, parseErr := time.Parse(time.RFC3339Nano, policy.ValidUntil)
	if parseErr != nil || !validUntil.After(c.now()) {
		return c.invalidatePolicyLocked(ctx, errors.New("托管连接策略已经失效"))
	}
	keys, validationErr := normalizeManagedPolicyKeys(policy.AllowedMobileKeys)
	if validationErr != nil {
		return c.invalidatePolicyLocked(ctx, validationErr)
	}
	next := c.state
	next.PolicyVersion = policy.PolicyVersion
	next.PolicyFetchedAt = c.now().Format(time.RFC3339Nano)
	next.PolicyValidUntil = validUntil.UTC().Format(time.RFC3339Nano)
	next.AllowedMobileKeys = keys
	next.AuthorizationInvalid = false
	if err := c.saveStateLocked(next); err != nil {
		return tailcatStatus{}, err
	}
	return c.applyPolicyLocked(ctx, keys)
}

func (c *managedPairingController) clearIdentityMismatchLocked(ctx context.Context) error {
	if err := c.clearRegistrationLocked(ctx); err != nil {
		return fmt.Errorf("清除已变化的 Tailcat 主机身份：%w", err)
	}
	return errors.New("Tailcat 主机身份已改变，需要重新托管配对")
}

func (c *managedPairingController) clearRegistrationLocked(ctx context.Context) error {
	_, applyErr := c.applyPolicyLocked(ctx, nil)
	saveErr := c.saveStateLocked(managedPairingState{Version: 1})
	return errors.Join(applyErr, saveErr)
}

func (c *managedPairingController) cachedPolicyFreshLocked() bool {
	if c.state.PolicyFetchedAt == "" || c.state.PolicyValidUntil == "" || c.state.AuthorizationInvalid {
		return false
	}
	fetchedAt, err := time.Parse(time.RFC3339Nano, c.state.PolicyFetchedAt)
	if err != nil || fetchedAt.After(c.now().Add(time.Minute)) {
		return false
	}
	validUntil, err := time.Parse(time.RFC3339Nano, c.state.PolicyValidUntil)
	if err != nil || !validUntil.After(c.now()) {
		return false
	}
	return c.now().Sub(fetchedAt) <= c.offlineTTL
}

func (c *managedPairingController) invalidatePolicyLocked(
	ctx context.Context,
	policyError error,
) (tailcatStatus, error) {
	next := c.state
	next.AllowedMobileKeys = nil
	next.PolicyFetchedAt = c.now().Format(time.RFC3339Nano)
	next.PolicyValidUntil = ""
	next.AuthorizationInvalid = true
	_, applyErr := c.applyPolicyLocked(ctx, nil)
	saveErr := c.saveStateLocked(next)
	if saveErr != nil {
		// 持久化失败时仍保留内存中的失效标记，避免下一次临时网络故障
		// 重新应用刚被服务端撤销的旧白名单。
		c.state = next
	}
	return tailcatStatus{}, errors.Join(policyError, applyErr, saveErr)
}

func (c *managedPairingController) applyPolicyLocked(
	ctx context.Context,
	keys []string,
) (tailcatStatus, error) {
	current := c.tailcat.Status(ctx)
	if c.hasApplied && current.InstanceID != "" && c.appliedInstanceID == current.InstanceID &&
		c.appliedHostKey == current.PublicKey && managedStringSlicesEqual(c.appliedKeys, keys) {
		return current, nil
	}
	status, err := c.tailcat.ReplaceManagedClients(ctx, append([]string(nil), keys...))
	if err != nil {
		return tailcatStatus{}, err
	}
	if !status.Running {
		return tailcatStatus{}, errors.New("Tailcat 稳定连接应用托管策略后未运行")
	}
	c.appliedKeys = append([]string(nil), keys...)
	c.appliedHostKey = status.PublicKey
	c.appliedInstanceID = status.InstanceID
	c.hasApplied = true
	return status, nil
}

func (c *managedPairingController) rotateHostTokenLocked() error {
	raw := make([]byte, 32)
	if _, err := io.ReadFull(c.random, raw); err != nil {
		return fmt.Errorf("生成 Mac 托管凭证：%w", err)
	}
	next := c.state
	next.Version = 1
	next.HostDeviceToken = base64.RawURLEncoding.EncodeToString(raw)
	next.HostID = ""
	next.MacTailcatPublicKey = ""
	c.clearPolicyInState(&next)
	return c.saveStateLocked(next)
}

func (c *managedPairingController) clearPolicyInState(state *managedPairingState) {
	state.PolicyVersion = 0
	state.PolicyFetchedAt = ""
	state.PolicyValidUntil = ""
	state.AllowedMobileKeys = nil
	state.AuthorizationInvalid = false
}

func (c *managedPairingController) saveStateLocked(next managedPairingState) error {
	if next.Version == 0 {
		next.Version = 1
	}
	if err := c.writeState(c.statePath, next); err != nil {
		return fmt.Errorf("保存托管连接策略：%w", err)
	}
	c.state = next
	c.stateLoadError = nil
	return nil
}

func (c *managedPairingController) doJSON(
	ctx context.Context,
	method string,
	requestPath string,
	bearer string,
	payload any,
	result any,
) error {
	var body io.Reader
	if payload != nil {
		encoded, err := json.Marshal(payload)
		if err != nil {
			return err
		}
		body = bytes.NewReader(encoded)
	}
	endpoint := *c.baseURL
	endpoint.Path = strings.TrimRight(endpoint.Path, "/") + requestPath
	request, err := http.NewRequestWithContext(ctx, method, endpoint.String(), body)
	if err != nil {
		return err
	}
	if payload != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	if bearer != "" {
		request.Header.Set("Authorization", "Bearer "+bearer)
	}
	response, err := c.httpClient.Do(request)
	if err != nil {
		return fmt.Errorf("连接 Mimi 托管服务失败：%w", err)
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		var failure struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		}
		_ = json.NewDecoder(io.LimitReader(response.Body, 32<<10)).Decode(&failure)
		return &managedCloudError{StatusCode: response.StatusCode, Code: failure.Code, Message: failure.Message}
	}
	if result == nil {
		return nil
	}
	if err := json.NewDecoder(io.LimitReader(response.Body, 64<<10)).Decode(result); err != nil {
		return fmt.Errorf("解析 Mimi 托管服务响应失败：%w", err)
	}
	return nil
}

func loadManagedPairingState(path string) (managedPairingState, error) {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return managedPairingState{Version: 1}, nil
	}
	if err != nil {
		return managedPairingState{}, fmt.Errorf("读取托管连接策略：%w", err)
	}
	if !info.Mode().IsRegular() {
		return managedPairingState{}, errors.New("托管连接策略必须是普通文件")
	}
	if runtime.GOOS != "windows" && info.Mode().Perm() != 0o600 {
		return managedPairingState{}, errors.New("托管连接策略权限必须为 0600")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return managedPairingState{}, fmt.Errorf("读取托管连接策略：%w", err)
	}
	var state managedPairingState
	if err := json.Unmarshal(data, &state); err != nil || state.Version != 1 {
		return managedPairingState{}, errors.New("托管连接策略格式损坏")
	}
	if state.HostDeviceToken != "" {
		if _, err := decodeManagedDeviceToken(state.HostDeviceToken); err != nil {
			return managedPairingState{}, errors.New("托管连接设备凭证损坏")
		}
	}
	if state.HostID != "" {
		parsedHostID, err := uuid.Parse(state.HostID)
		if err != nil || parsedHostID.Version() != 4 || state.HostDeviceToken == "" ||
			!validManagedTailcatPublicKey(state.MacTailcatPublicKey) {
			return managedPairingState{}, errors.New("托管连接主机身份损坏")
		}
	} else if state.MacTailcatPublicKey != "" || state.PolicyVersion != 0 || state.PolicyFetchedAt != "" ||
		state.PolicyValidUntil != "" || len(state.AllowedMobileKeys) != 0 || state.AuthorizationInvalid {
		return managedPairingState{}, errors.New("托管连接策略缺少主机身份")
	}
	if _, err := normalizeManagedPolicyKeys(state.AllowedMobileKeys); err != nil {
		return managedPairingState{}, err
	}
	return state, nil
}

func writeManagedPairingState(path string, state managedPairingState) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	data, err := json.Marshal(state)
	if err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".managed-policy-*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o600); err != nil {
		_ = temporary.Close()
		return err
	}
	if _, err := temporary.Write(data); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(temporaryPath, path)
}

func decodeManagedDeviceToken(value string) ([]byte, error) {
	decoded, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(value))
	if err != nil || len(decoded) != 32 || base64.RawURLEncoding.EncodeToString(decoded) != value {
		return nil, errors.New("设备凭证必须是 256 位 canonical base64url")
	}
	return decoded, nil
}

func normalizeManagedPolicyKeys(rawKeys []string) ([]string, error) {
	if len(rawKeys) > 5 {
		return nil, errors.New("托管连接策略超过移动设备上限")
	}
	seen := make(map[string]struct{}, len(rawKeys))
	keys := make([]string, 0, len(rawKeys))
	for _, rawKey := range rawKeys {
		key := strings.TrimSpace(rawKey)
		if !validManagedTailcatPublicKey(key) {
			return nil, errors.New("托管连接策略包含无效 Tailcat 公钥")
		}
		if _, exists := seen[key]; exists {
			return nil, errors.New("托管连接策略包含重复 Tailcat 公钥")
		}
		seen[key] = struct{}{}
		keys = append(keys, key)
	}
	return keys, nil
}

func validManagedTailcatPublicKey(value string) bool {
	if value == "" || len(value) > 72 || !utf8.ValidString(value) || strings.TrimSpace(value) != value {
		return false
	}
	for _, character := range value {
		if character < 32 || character == 127 {
			return false
		}
	}
	return true
}

func isManagedCloudCode(err error, code string) bool {
	var cloudError *managedCloudError
	return errors.As(err, &cloudError) && cloudError.Code == code
}

func containsString(values []string, expected string) bool {
	for _, value := range values {
		if value == expected {
			return true
		}
	}
	return false
}

func managedStringSlicesEqual(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}
