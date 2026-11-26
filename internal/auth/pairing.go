package auth

import (
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"strings"
	"time"
)

var (
	ErrPairTicketInvalid = errors.New("配对票据无效")
	ErrPairTicketExpired = errors.New("配对二维码已过期")
	ErrPairClockSkew     = errors.New("配对票据 issued_at 超出允许范围")
)

// Older clients also consume the original detail for malformed tickets.
type invalidPairingTicket string

func (e invalidPairingTicket) Error() string { return string(e) }
func (invalidPairingTicket) Unwrap() error   { return ErrPairTicketInvalid }

type PairingTicket struct {
	Endpoint  string `json:"endpoint"`
	IssuedAt  string `json:"issued_at"`
	ExpiresAt string `json:"expires_at"`
	Signature string `json:"pair_sig"`
}

func NewPairingTicket(endpoint string, secret string, issuedAt time.Time, expiresAt time.Time) PairingTicket {
	ticket := PairingTicket{
		Endpoint: strings.TrimSpace(endpoint),
		// 保留亚秒精度，确保用户连续刷新二维码时仍生成可区分的新票据，
		// 也便于按每张票据自己的签发和过期时间审计生命周期。
		// time.Parse(RFC3339Nano) 仍兼容旧版本生成的不含小数秒 RFC3339 时间。
		IssuedAt:  issuedAt.UTC().Format(time.RFC3339Nano),
		ExpiresAt: expiresAt.UTC().Format(time.RFC3339Nano),
	}
	ticket.Signature = SignPairingTicket(secret, ticket.Endpoint, ticket.IssuedAt, ticket.ExpiresAt)
	return ticket
}

func SignPairingTicket(secret string, endpoint string, issuedAt string, expiresAt string) string {
	mac := hmac.New(sha256.New, []byte(strings.TrimSpace(secret)))
	mac.Write([]byte(strings.TrimSpace(endpoint)))
	mac.Write([]byte{'\n'})
	mac.Write([]byte(strings.TrimSpace(issuedAt)))
	mac.Write([]byte{'\n'})
	mac.Write([]byte(strings.TrimSpace(expiresAt)))
	return hex.EncodeToString(mac.Sum(nil))
}

func ValidatePairingTicket(secret string, ticket PairingTicket, now time.Time) error {
	secret = strings.TrimSpace(secret)
	endpoint := strings.TrimSpace(ticket.Endpoint)
	issuedAt := strings.TrimSpace(ticket.IssuedAt)
	expiresAt := strings.TrimSpace(ticket.ExpiresAt)
	signature := strings.TrimSpace(ticket.Signature)
	if secret == "" {
		return invalidPairingTicket("配对不可用：auth.token 未配置")
	}
	if endpoint == "" || issuedAt == "" || expiresAt == "" || signature == "" {
		return invalidPairingTicket("配对票据缺少必要字段")
	}
	// Keep the historical time-error text for legacy clients. Only signed
	// timestamps can produce the expired or clock-skew diagnostic sentinel.
	expiry, expiryErr := time.Parse(time.RFC3339Nano, expiresAt)
	issued, issuedErr := time.Parse(time.RFC3339Nano, issuedAt)
	var timeFailure error
	switch {
	case expiryErr != nil:
		timeFailure = invalidPairingTicket("配对票据 expires_at 无效")
	case !now.Before(expiry):
		timeFailure = ErrPairTicketExpired
	case issuedErr != nil:
		timeFailure = invalidPairingTicket("配对票据 issued_at 无效")
	case issued.After(now.Add(2 * time.Minute)):
		timeFailure = ErrPairClockSkew
	}

	expected := SignPairingTicket(secret, endpoint, issuedAt, expiresAt)
	if subtle.ConstantTimeCompare([]byte(signature), []byte(expected)) != 1 {
		if timeFailure != nil {
			return invalidPairingTicket(timeFailure.Error())
		}
		return invalidPairingTicket("配对票据签名无效")
	}
	if issuedErr == nil && expiryErr == nil && !expiry.After(issued) {
		if timeFailure != nil {
			return invalidPairingTicket(timeFailure.Error())
		}
		return invalidPairingTicket("配对票据 expires_at 无效")
	}
	return timeFailure
}
