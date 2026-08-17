//go:build darwin

package appserver

import (
	"encoding/binary"
	"testing"
)

func sharedDaemonTestCSOpsStringBlob(payload []byte) []byte {
	buffer := make([]byte, 8+len(payload)+1)
	binary.BigEndian.PutUint32(buffer[4:8], uint32(len(buffer)))
	copy(buffer[8:], payload)
	buffer[len(buffer)-1] = 0
	return buffer
}

func TestParseSharedDaemonCSOpsStringBlobAcceptsCanonicalNULTermination(t *testing.T) {
	want := "com.openai.codex"
	got, err := parseSharedDaemonCSOpsStringBlob(sharedDaemonTestCSOpsStringBlob([]byte(want)))
	if err != nil {
		t.Fatalf("规范 CSOPS string blob 应通过：%v", err)
	}
	if got != want {
		t.Fatalf("CSOPS string blob 解析错误：got=%q want=%q", got, want)
	}
}

func TestParseSharedDaemonCSOpsStringBlobRejectsInvalidLength(t *testing.T) {
	valid := sharedDaemonTestCSOpsStringBlob([]byte("codex"))
	tests := map[string][]byte{
		"short header": valid[:8],
		"unexpected header type": func() []byte {
			candidate := append([]byte(nil), valid...)
			binary.BigEndian.PutUint32(candidate[0:4], 1)
			return candidate
		}(),
		"total shorter than header and NUL": func() []byte {
			candidate := append([]byte(nil), valid...)
			binary.BigEndian.PutUint32(candidate[4:8], 8)
			return candidate
		}(),
		"total exceeds buffer": func() []byte {
			candidate := append([]byte(nil), valid...)
			binary.BigEndian.PutUint32(candidate[4:8], uint32(len(candidate)+1))
			return candidate
		}(),
	}
	for name, candidate := range tests {
		t.Run(name, func(t *testing.T) {
			if _, err := parseSharedDaemonCSOpsStringBlob(candidate); err == nil {
				t.Fatal("非法 CSOPS blob 长度必须 fail closed")
			}
		})
	}
}

func TestParseSharedDaemonCSOpsStringBlobRejectsNonCanonicalNUL(t *testing.T) {
	valid := sharedDaemonTestCSOpsStringBlob([]byte("codex"))
	tests := map[string][]byte{
		"missing final NUL": func() []byte {
			candidate := append([]byte(nil), valid...)
			candidate[len(candidate)-1] = 'x'
			return candidate
		}(),
		"embedded NUL":  sharedDaemonTestCSOpsStringBlob([]byte{'c', 0, 'd', 'e', 'x'}),
		"empty payload": sharedDaemonTestCSOpsStringBlob(nil),
	}
	for name, candidate := range tests {
		t.Run(name, func(t *testing.T) {
			if _, err := parseSharedDaemonCSOpsStringBlob(candidate); err == nil {
				t.Fatal("非规范 CSOPS blob NUL 必须 fail closed")
			}
		})
	}
}
