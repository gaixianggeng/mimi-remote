package pushprovider

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// Push Ticket 是 Provider 发给设备、再由设备交给自己 agentd 的不透明凭据。
// agentd 只保存密文、到期时间和 device_id，看不到里面的 APNs Device Token；
// Provider 也因此不需要长期保存 Token —— 它每次投递时从 Ticket 里解出来即可。
//
// 遗失一张 Ticket 最多只能向绑定的那一台设备发送固定格式的 Mimi 通知：它不能
// 访问 agentd，不能批准任何请求，也不能读出会话内容。
const (
	ticketPrefix        = "mpt1"
	ticketMaxLifetime   = 30 * 24 * time.Hour
	ticketMaxEncodedLen = 2048
)

var (
	errTicketMalformed = errors.New("push ticket 格式无效")
	errTicketKeyUnkown = errors.New("push ticket 使用了未知密钥版本")
	errTicketExpired   = errors.New("push ticket 已过期")
)

type TicketClaims struct {
	Version int `json:"v"`
	// ID 是撤销表里唯一会被持久化的字段。
	ID          string `json:"tid"`
	Environment string `json:"env"`
	Topic       string `json:"topic"`
	DeviceToken string `json:"dt"`
	// InstallDigest 是设备随机安装标识的摘要，只用于把 Ticket 绑定到一次安装，
	// 不能反查用户身份。
	InstallDigest string `json:"idg"`
	IssuedAt      int64  `json:"iat"`
	ExpiresAt     int64  `json:"exp"`
}

func (c TicketClaims) Expiry() time.Time { return time.Unix(c.ExpiresAt, 0).UTC() }

// TicketSealer 用认证加密封装 Ticket。轮换期间同时保留上一版密钥，让已经发出去
// 的 Ticket 在自然到期前继续可用。
type TicketSealer struct {
	currentVersion int
	keys           map[int]cipher.AEAD
	lifetime       time.Duration
}

func NewTicketSealer(keys map[int][]byte, currentVersion int, lifetime time.Duration) (*TicketSealer, error) {
	if len(keys) == 0 {
		return nil, errors.New("至少需要一个 ticket 加密密钥")
	}
	if _, ok := keys[currentVersion]; !ok {
		return nil, fmt.Errorf("当前密钥版本 %d 不在密钥集中", currentVersion)
	}
	if lifetime <= 0 || lifetime > ticketMaxLifetime {
		lifetime = ticketMaxLifetime
	}
	sealer := &TicketSealer{currentVersion: currentVersion, keys: map[int]cipher.AEAD{}, lifetime: lifetime}
	for version, key := range keys {
		if len(key) != 32 {
			return nil, fmt.Errorf("密钥版本 %d 长度必须是 32 字节", version)
		}
		block, err := aes.NewCipher(key)
		if err != nil {
			return nil, err
		}
		aead, err := cipher.NewGCM(block)
		if err != nil {
			return nil, err
		}
		sealer.keys[version] = aead
	}
	return sealer, nil
}

func (s *TicketSealer) Lifetime() time.Duration { return s.lifetime }

func (s *TicketSealer) Seal(claims TicketClaims) (string, error) {
	aead, ok := s.keys[s.currentVersion]
	if !ok {
		return "", errTicketKeyUnkown
	}
	claims.Version = 1
	plaintext, err := json.Marshal(claims)
	if err != nil {
		return "", err
	}
	nonce := make([]byte, aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return "", err
	}
	// 密钥版本参与认证，攻击者不能把密文挪到另一版密钥下重放。
	aad := []byte(ticketPrefix + "." + strconv.Itoa(s.currentVersion))
	sealed := aead.Seal(nonce, nonce, plaintext, aad)
	return ticketPrefix + "." + strconv.Itoa(s.currentVersion) + "." +
		base64.RawURLEncoding.EncodeToString(sealed), nil
}

func (s *TicketSealer) Open(ticket string, now time.Time) (TicketClaims, error) {
	if len(ticket) > ticketMaxEncodedLen {
		return TicketClaims{}, errTicketMalformed
	}
	parts := strings.Split(ticket, ".")
	if len(parts) != 3 || parts[0] != ticketPrefix {
		return TicketClaims{}, errTicketMalformed
	}
	version, err := strconv.Atoi(parts[1])
	if err != nil {
		return TicketClaims{}, errTicketMalformed
	}
	aead, ok := s.keys[version]
	if !ok {
		return TicketClaims{}, errTicketKeyUnkown
	}
	sealed, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || len(sealed) < aead.NonceSize() {
		return TicketClaims{}, errTicketMalformed
	}
	nonce, ciphertext := sealed[:aead.NonceSize()], sealed[aead.NonceSize():]
	aad := []byte(ticketPrefix + "." + parts[1])
	plaintext, err := aead.Open(nil, nonce, ciphertext, aad)
	if err != nil {
		return TicketClaims{}, errTicketMalformed
	}
	var claims TicketClaims
	if err := json.Unmarshal(plaintext, &claims); err != nil {
		return TicketClaims{}, errTicketMalformed
	}
	if claims.Version != 1 || claims.ID == "" || claims.DeviceToken == "" || claims.Topic == "" {
		return TicketClaims{}, errTicketMalformed
	}
	if claims.ExpiresAt <= now.Unix() {
		return TicketClaims{}, errTicketExpired
	}
	return claims, nil
}

func (s *TicketSealer) Issue(environment string, topic string, deviceToken string, installDigest string, now time.Time) (string, TicketClaims, error) {
	id, err := randomTicketID()
	if err != nil {
		return "", TicketClaims{}, err
	}
	claims := TicketClaims{
		ID:            id,
		Environment:   environment,
		Topic:         topic,
		DeviceToken:   deviceToken,
		InstallDigest: installDigest,
		IssuedAt:      now.Unix(),
		ExpiresAt:     now.Add(s.lifetime).Unix(),
	}
	ticket, err := s.Seal(claims)
	if err != nil {
		return "", TicketClaims{}, err
	}
	return ticket, claims, nil
}

func randomTicketID() (string, error) {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf), nil
}

// installationDigest 只保留安装标识的摘要。Provider 因此无法把 Ticket 反查回
// 某台设备的原始安装 ID，日志里也不会出现它。
func installationDigest(installation string) string {
	digest := sha256.Sum256([]byte("mimi-install:" + strings.TrimSpace(installation)))
	return hex.EncodeToString(digest[:])[:32]
}
