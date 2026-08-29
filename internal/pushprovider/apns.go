package pushprovider

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	APNsProductionHost = "https://api.push.apple.com"
	APNsSandboxHost    = "https://api.sandbox.push.apple.com"
	// Apple 要求 provider token 至少每小时重建一次，且不得快于每 20 分钟一次。
	apnsTokenLifetime      = 45 * time.Minute
	maxTransportError      = 256
	apnsPushTypeAlert      = "alert"
	apnsPushTypeBackground = "background"
)

// APNsCredentials 只在 Provider 进程内存在。私钥来自部署平台的 Secret Store 或
// 权限 0600 的外部文件，绝不进入 iOS App、agentd、仓库或 Release 资产。
type APNsCredentials struct {
	KeyID  string
	TeamID string
	Key    *ecdsa.PrivateKey
}

func ParseAPNsAuthKey(pemBytes []byte, keyID string, teamID string) (APNsCredentials, error) {
	keyID = strings.TrimSpace(keyID)
	teamID = strings.TrimSpace(teamID)
	if keyID == "" || teamID == "" {
		return APNsCredentials{}, errors.New("APNs Key ID 与 Team ID 不能为空")
	}
	block, _ := pem.Decode(pemBytes)
	if block == nil {
		return APNsCredentials{}, errors.New("APNs .p8 不是有效的 PEM")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return APNsCredentials{}, fmt.Errorf("解析 APNs .p8 失败: %w", err)
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok {
		return APNsCredentials{}, errors.New("APNs .p8 不是 ECDSA 私钥")
	}
	return APNsCredentials{KeyID: keyID, TeamID: teamID, Key: key}, nil
}

// APNsClient 维护 provider token 缓存与 HTTP/2 连接。Go 的默认 Transport 通过
// ALPN 协商 h2，APNs 不接受 HTTP/1.1。
type APNsClient struct {
	host        string
	credentials APNsCredentials
	http        *http.Client

	mu          sync.Mutex
	token       string
	tokenIssued time.Time
	now         func() time.Time
}

func NewAPNsClient(host string, credentials APNsCredentials) *APNsClient {
	return &APNsClient{
		host:        strings.TrimRight(host, "/"),
		credentials: credentials,
		http: &http.Client{
			Timeout:   10 * time.Second,
			Transport: &http.Transport{ForceAttemptHTTP2: true, MaxIdleConnsPerHost: 4},
		},
		now: time.Now,
	}
}

type APNsResult struct {
	StatusCode int
	Reason     string
	APNsID     string
}

// Unregistered 表示设备 Token 已失效，调用方应当撤销对应 Ticket 而不是重试。
func (r APNsResult) Unregistered() bool {
	return r.StatusCode == http.StatusGone ||
		r.Reason == "Unregistered"
}

func (r APNsResult) OK() bool { return r.StatusCode == http.StatusOK }

// APNsRequest 是 Provider 自己组装出来的完整投递请求。调用方只能提供枚举与标识，
// 不能提供任意 header 或 aps 字典。
type APNsRequest struct {
	DeviceToken string
	Topic       string
	PushType    string
	CollapseID  string
	Expiration  time.Time
	Priority    int
	Payload     []byte
}

func (c *APNsClient) Push(ctx context.Context, request APNsRequest) (APNsResult, error) {
	token, err := c.providerToken()
	if err != nil {
		return APNsResult{}, safeTransportError(err, request.DeviceToken)
	}
	url := c.host + "/3/device/" + request.DeviceToken
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(request.Payload))
	if err != nil {
		return APNsResult{}, safeTransportError(err, request.DeviceToken)
	}
	pushType := request.PushType
	if pushType == "" {
		// 保持直接调用 APNsClient 的旧行为；Provider 业务路径会显式选择类型。
		pushType = apnsPushTypeAlert
	}
	if pushType != apnsPushTypeAlert && pushType != apnsPushTypeBackground {
		return APNsResult{}, fmt.Errorf("invalid APNs push type %q", pushType)
	}
	req.Header.Set("authorization", "bearer "+token)
	req.Header.Set("apns-topic", request.Topic)
	req.Header.Set("apns-push-type", pushType)
	if request.Priority > 0 {
		req.Header.Set("apns-priority", strconv.Itoa(request.Priority))
	}
	if request.CollapseID != "" {
		req.Header.Set("apns-collapse-id", request.CollapseID)
	}
	if !request.Expiration.IsZero() {
		req.Header.Set("apns-expiration", strconv.FormatInt(request.Expiration.Unix(), 10))
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return APNsResult{}, safeTransportError(err, request.DeviceToken)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<10))
	result := APNsResult{StatusCode: resp.StatusCode, APNsID: resp.Header.Get("apns-id")}
	if len(body) > 0 {
		var payload struct {
			Reason string `json:"reason"`
		}
		if json.Unmarshal(body, &payload) == nil {
			result.Reason = payload.Reason
		}
	}
	if resp.StatusCode == http.StatusForbidden {
		// ExpiredProviderToken / InvalidProviderToken：立刻作废缓存，下一次重新签发。
		c.invalidateToken()
	}
	return result, nil
}

// safeTransportError 保留有限的网络诊断，但移除错误字符串中可能被 net/http
// 拼入的 Device Token。返回值不包装原始 error，避免调用方
// 通过 Unwrap 或格式化原始错误再次泄漏敏感标识。
func safeTransportError(err error, deviceToken string) error {
	if err == nil {
		return nil
	}
	diagnostic := strings.TrimSpace(err.Error())
	if deviceToken != "" {
		diagnostic = strings.ReplaceAll(diagnostic, deviceToken, "[REDACTED]")
		diagnostic = strings.ReplaceAll(diagnostic, strings.ToUpper(deviceToken), "[REDACTED]")
	}
	if len(diagnostic) > maxTransportError {
		diagnostic = diagnostic[:maxTransportError-len("...")] + "..."
	}
	if diagnostic == "" {
		diagnostic = "unknown transport error"
	}
	return errors.New(diagnostic)
}

func (c *APNsClient) providerToken() (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.now()
	if c.token != "" && now.Sub(c.tokenIssued) < apnsTokenLifetime {
		return c.token, nil
	}
	token, err := signAPNsProviderToken(c.credentials, now)
	if err != nil {
		return "", err
	}
	c.token = token
	c.tokenIssued = now
	return token, nil
}

func (c *APNsClient) invalidateToken() {
	c.mu.Lock()
	c.token = ""
	c.mu.Unlock()
}

// signAPNsProviderToken 手写 ES256 JWT。这里只需要 Apple 规定的固定三段结构，
// 引入完整 JWT 库不会更安全，只会多一条供应链依赖。
func signAPNsProviderToken(credentials APNsCredentials, now time.Time) (string, error) {
	header, err := json.Marshal(map[string]string{"alg": "ES256", "kid": credentials.KeyID})
	if err != nil {
		return "", err
	}
	claims, err := json.Marshal(map[string]any{"iss": credentials.TeamID, "iat": now.Unix()})
	if err != nil {
		return "", err
	}
	signingInput := base64.RawURLEncoding.EncodeToString(header) + "." +
		base64.RawURLEncoding.EncodeToString(claims)
	digest := sha256.Sum256([]byte(signingInput))
	signature, err := signES256(credentials.Key, digest[:])
	if err != nil {
		return "", err
	}
	return signingInput + "." + base64.RawURLEncoding.EncodeToString(signature), nil
}

// signES256 输出 JOSE 要求的定长 r||s，而不是 ecdsa.SignASN1 的 DER。
func signES256(key *ecdsa.PrivateKey, digest []byte) ([]byte, error) {
	der, err := ecdsa.SignASN1(rand.Reader, key, digest)
	if err != nil {
		return nil, err
	}
	var parsed struct {
		R *big.Int
		S *big.Int
	}
	if _, err := asn1.Unmarshal(der, &parsed); err != nil {
		return nil, err
	}
	size := (key.Curve.Params().BitSize + 7) / 8
	signature := make([]byte, 2*size)
	parsed.R.FillBytes(signature[:size])
	parsed.S.FillBytes(signature[size:])
	return signature, nil
}
