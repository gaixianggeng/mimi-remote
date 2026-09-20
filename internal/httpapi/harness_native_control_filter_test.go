package httpapi

import (
	"bytes"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"
)

// 非空样例按冻结版本 control.ts 构造，明确不是 live-capture。
func TestHarnessNativeControlFilterMixedBaseline(t *testing.T) {
	raw := json.RawMessage(`{"type":"baseline","value":{
		"queues":{"allowed":[{"message":{"content":[{"text":"kept"}]}}],"private":[{"text":"SECRET-QUEUE"}]},
		"jobs":{"allowed":[{"id":"job-a","detail":"kept"}],"private":[{"detail":"SECRET-JOB"}]},
		"projections":{"allowed":{"asOfSeq":7,"values":{"title":"kept"}},"private":{"asOfSeq":9,"values":{"title":"SECRET-PROJECTION"}}}
	}}`)
	original := bytes.Clone(raw)
	calls := map[string]int{}
	out, err := harnessNativeFilterControl(raw, func(id string) (bool, error) {
		calls[id]++
		return id == "allowed", nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(out), "private") || strings.Contains(string(out), "SECRET") {
		t.Fatalf("unapproved baseline data escaped: %s", out)
	}
	if !bytes.Equal(raw, original) {
		t.Fatal("filter mutated its input")
	}
	if !reflect.DeepEqual(calls, map[string]int{"allowed": 1, "private": 1}) {
		t.Fatalf("authorize once per unique session, got %v", calls)
	}
	var before, after struct {
		Value map[string]map[string]json.RawMessage `json:"value"`
	}
	if err := json.Unmarshal(raw, &before); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(out, &after); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"queues", "jobs", "projections"} {
		if len(after.Value[key]) != 1 {
			t.Fatalf("unexpected %s entries: %s", key, out)
		}
		var want, got any
		_ = json.Unmarshal(before.Value[key]["allowed"], &want)
		_ = json.Unmarshal(after.Value[key]["allowed"], &got)
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("native payload changed in %s", key)
		}
	}
}

func TestHarnessNativeControlFilterDeltas(t *testing.T) {
	for _, raw := range []string{
		`{"type":"projection","sessionId":"a","key":"title","value":null,"seq":4}`,
		`{"type":"queue","sessionId":"a","items":[]}`,
		`{"type":"jobs","sessionId":"a","jobs":[{"id":"job-a"}]}`,
	} {
		t.Run(raw, func(t *testing.T) {
			out, err := harnessNativeFilterControl([]byte(raw), func(id string) (bool, error) {
				if id != "a" {
					t.Fatalf("wrong authorization identity: %q", id)
				}
				return true, nil
			})
			if err != nil || string(out) != raw {
				t.Fatalf("authorized delta must remain native: %s / %v", out, err)
			}
			out, err = harnessNativeFilterControl([]byte(raw), func(string) (bool, error) { return false, nil })
			if err != nil || out != nil {
				t.Fatalf("unauthorized delta escaped: %s / %v", out, err)
			}
		})
	}
}

func TestHarnessNativeControlFilterRejectsUnknownOrMalformedEnvelope(t *testing.T) {
	cases := []string{
		`not-json`, `null`, `[]`, `{}`, `{"type":1}`,
		`{"type":"unknown","sessionId":"a","secret":"x"}`,
		`{"type":"baseline","value":null}`,
		`{"type":"baseline","value":{"jobs":{},"projections":{}}}`,
		`{"type":"baseline","value":{"queues":{},"jobs":{},"projections":{},"secret":{}}}`,
		`{"type":"baseline","value":{"queues":{},"jobs":{},"projections":{}},"secret":"x"}`,
		`{"type":"baseline","value":{"queues":[],"jobs":{},"projections":{}}}`,
		`{"type":"baseline","value":{"queues":{},"jobs":null,"projections":{}}}`,
		`{"type":"baseline","value":{"queues":{},"jobs":{},"projections":[]}}`,
		`{"type":"baseline","value":{"queues":{" ":[]},"jobs":{},"projections":{}}}`,
		`{"type":"queue","items":[]}`,
		`{"type":"queue","sessionId":" a ","items":[]}`,
		`{"type":"queue","sessionId":"a\u0000b","items":[]}`,
		`{"type":"queue","sessionId":"a","items":[],"private":"x"}`,
	}
	for _, raw := range cases {
		t.Run(raw, func(t *testing.T) {
			out, err := harnessNativeFilterControl([]byte(raw), func(string) (bool, error) {
				t.Fatal("malformed control data reached authorization")
				return true, nil
			})
			if !errors.Is(err, errHarnessNativeControlShape) || out != nil {
				t.Fatalf("invalid envelope must fail closed: %s / %v", out, err)
			}
		})
	}
}

func TestHarnessNativeControlFilterAuthorizationFailureIsNotEmptySuccess(t *testing.T) {
	failure := errors.New("directory unavailable")
	for _, raw := range []string{
		`{"type":"baseline","value":{"queues":{"a":[]},"jobs":{},"projections":{}}}`,
		`{"type":"jobs","sessionId":"a","jobs":[]}`,
	} {
		out, err := harnessNativeFilterControl([]byte(raw), func(string) (bool, error) { return false, failure })
		if !errors.Is(err, failure) || out != nil {
			t.Fatalf("authorization error lost: %s / %v", out, err)
		}
	}
}

func TestHarnessNativeControlFilterEmptyBaselineAndFullyDeniedBaseline(t *testing.T) {
	for _, raw := range []string{
		`{"type":"baseline","value":{"queues":{},"jobs":{},"projections":{}}}`,
		`{"type":"baseline","value":{"queues":{"denied":[]},"jobs":{"denied":[]},"projections":{"denied":{}}}}`,
	} {
		out, err := harnessNativeFilterControl([]byte(raw), func(string) (bool, error) { return false, nil })
		if err != nil {
			t.Fatal(err)
		}
		var decoded struct {
			Value map[string]map[string]json.RawMessage `json:"value"`
		}
		if err := json.Unmarshal(out, &decoded); err != nil {
			t.Fatal(err)
		}
		for _, key := range []string{"queues", "jobs", "projections"} {
			if decoded.Value[key] == nil || len(decoded.Value[key]) != 0 {
				t.Fatalf("empty dictionary must remain {} in %s: %s", key, out)
			}
		}
	}
}

func TestHarnessNativeControlFilterDoesNotCacheAuthorizationBetweenFrames(t *testing.T) {
	raw := []byte(`{"type":"queue","sessionId":"a","items":[]}`)
	allowed := true
	authorize := func(string) (bool, error) { return allowed, nil }
	first, err := harnessNativeFilterControl(raw, authorize)
	if err != nil || first == nil {
		t.Fatalf("first authorized delta missing: %v", err)
	}
	allowed = false
	second, err := harnessNativeFilterControl(raw, authorize)
	if err != nil || second != nil {
		t.Fatalf("revoked session must disappear from later frames: %s / %v", second, err)
	}
}
