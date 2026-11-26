package auth

import (
	"errors"
	"strings"
	"testing"
	"time"
)

func TestPairingTicketValidatesSignatureAndExpiry(t *testing.T) {
	now := time.Date(2026, 6, 29, 10, 0, 0, 0, time.UTC)
	ticket := NewPairingTicket("http://100.64.0.1:8787", "0123456789abcdef0123456789abcdef", now, now.Add(10*time.Minute))

	if err := ValidatePairingTicket("0123456789abcdef0123456789abcdef", ticket, now.Add(time.Minute)); err != nil {
		t.Fatalf("合法配对票据应通过校验：%v", err)
	}

	ticket.Endpoint = "http://100.64.0.2:8787"
	if err := ValidatePairingTicket("0123456789abcdef0123456789abcdef", ticket, now.Add(time.Minute)); err == nil || !strings.Contains(err.Error(), "签名") {
		t.Fatalf("篡改 endpoint 应导致签名失败，got=%v", err)
	}
}

func TestPairingTicketRejectsExpiredTicket(t *testing.T) {
	now := time.Date(2026, 6, 29, 10, 0, 0, 0, time.UTC)
	ticket := NewPairingTicket("http://100.64.0.1:8787", "0123456789abcdef0123456789abcdef", now.Add(-20*time.Minute), now.Add(-10*time.Minute))

	if err := ValidatePairingTicket("0123456789abcdef0123456789abcdef", ticket, now); err == nil || !strings.Contains(err.Error(), "过期") {
		t.Fatalf("过期配对票据应被拒绝，got=%v", err)
	}
}

func TestPairingTicketRejectsAtExactExpiryAfterRepeatedValidation(t *testing.T) {
	secret := "0123456789abcdef0123456789abcdef"
	issuedAt := time.Date(2026, 6, 29, 10, 0, 0, 0, time.UTC)
	expiresAt := issuedAt.Add(10 * time.Minute)
	ticket := NewPairingTicket("http://100.64.0.1:8787", secret, issuedAt, expiresAt)

	for attempt := 1; attempt <= 2; attempt++ {
		if err := ValidatePairingTicket(secret, ticket, expiresAt.Add(-time.Nanosecond)); err != nil {
			t.Fatalf("到期前第 %d 次校验应成功：%v", attempt, err)
		}
	}
	for _, now := range []time.Time{expiresAt, expiresAt.Add(time.Nanosecond)} {
		if err := ValidatePairingTicket(secret, ticket, now); err == nil || !strings.Contains(err.Error(), "过期") {
			t.Fatalf("到期瞬间及之后必须拒绝：now=%s err=%v", now, err)
		}
	}
}

func TestPairingTicketUsesSubsecondPrecisionAndAcceptsLegacyTimestamp(t *testing.T) {
	secret := "0123456789abcdef0123456789abcdef"
	base := time.Date(2026, 7, 13, 8, 0, 0, 100, time.UTC)
	first := NewPairingTicket("http://100.64.0.1:8787", secret, base, base.Add(10*time.Minute))
	second := NewPairingTicket("http://100.64.0.1:8787", secret, base.Add(200*time.Nanosecond), base.Add(10*time.Minute+200*time.Nanosecond))
	if first.Signature == second.Signature {
		t.Fatal("同一秒内刷新生成的票据必须可区分")
	}

	legacyIssued := base.Format(time.RFC3339)
	legacyExpires := base.Add(10 * time.Minute).Format(time.RFC3339)
	legacy := PairingTicket{
		Endpoint:  "http://100.64.0.1:8787",
		IssuedAt:  legacyIssued,
		ExpiresAt: legacyExpires,
		Signature: SignPairingTicket(secret, "http://100.64.0.1:8787", legacyIssued, legacyExpires),
	}
	if err := ValidatePairingTicket(secret, legacy, base.Add(time.Minute)); err != nil {
		t.Fatalf("升级后仍应接受有效的旧 RFC3339 票据：%v", err)
	}
}

func TestPairingTicketSentinels(t *testing.T) {
	const secret = "fixture-signing-key"
	now := time.Date(2026, 1, 1, 10, 0, 0, 0, time.UTC)
	for _, tc := range []struct {
		name            string
		issued, expires time.Duration
		tampered        bool
		want            error
	}{
		{"valid", 0, time.Minute, false, nil},
		{"expired", -time.Hour, 0, false, ErrPairTicketExpired},
		{"future", 2*time.Minute + time.Nanosecond, time.Hour, false, ErrPairClockSkew},
		{"skew boundary", 2 * time.Minute, time.Hour, false, nil},
		{"invalid interval", time.Minute, 0, false, ErrPairTicketInvalid},
		{"tampered expired", -time.Hour, 0, true, ErrPairTicketInvalid},
		{"tampered future", 3 * time.Minute, time.Hour, true, ErrPairTicketInvalid},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ticket := NewPairingTicket("http://pair.example.invalid", secret, now.Add(tc.issued), now.Add(tc.expires))
			if tc.tampered {
				ticket.Endpoint += "/other"
			}
			got := ValidatePairingTicket(secret, ticket, now)
			if !errors.Is(got, tc.want) {
				t.Fatalf("got %v, want %v", got, tc.want)
			}
		})
	}
}
