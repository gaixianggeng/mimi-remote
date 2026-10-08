//go:build darwin

package appserver

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestFrontDoorRuntimeUpdateSafetyAndVerification(t *testing.T) {
	pending := CodexRuntimeVersions{"0.161.0", "0.155.1", true}
	current := CodexRuntimeVersions{"0.161.0", "0.161.0", false}
	for _, tc := range []struct {
		name           string
		initial, after CodexRuntimeVersions
		fail           string
		wantEvents     []string
		wantError      string
	}{
		{"success", pending, current, "", []string{"read", "lock", "read", "stop", "unlock", "resume", "read"}, ""},
		{"already current", current, current, "", []string{"read"}, ""},
		{"installed older", CodexRuntimeVersions{"0.155.1", "0.161.0", false}, current, "", []string{"read"}, ""},
		{"unknown version", pending, current, "read", []string{"read"}, "read failed"},
		{"connected client", pending, current, "lock", []string{"read", "lock"}, "共享连接"},
		{"active or queued work", pending, current, "stop", []string{"read", "lock", "read", "stop", "unlock"}, "排队消息"},
		{"launch failure", pending, current, "resume", []string{"read", "lock", "read", "stop", "unlock", "resume"}, "新版尚未连接"},
		{"wrong replacement", pending, pending, "", []string{"read", "lock", "read", "stop", "unlock", "resume", "read"}, "尚未完成版本切换"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var events []string
			resumed := false
			ops := frontDoorUpdateOps{
				versions: func(context.Context) (CodexRuntimeVersions, error) {
					events = append(events, "read")
					if tc.fail == "read" {
						return CodexRuntimeVersions{}, errors.New("read failed")
					}
					if resumed {
						return tc.after, nil
					}
					return tc.initial, nil
				},
				lock: func(ctx context.Context) (func(), error) {
					events = append(events, "lock")
					if deadline, ok := ctx.Deadline(); !ok || time.Until(deadline) > 2*time.Second {
						t.Fatal("共享连接阻塞必须有短等待预算")
					}
					if tc.fail == "lock" {
						return nil, context.DeadlineExceeded
					}
					return func() { events = append(events, "unlock") }, nil
				},
				stop: func(context.Context) error {
					events = append(events, "stop")
					if tc.fail == "stop" {
						return errors.New("busy")
					}
					return nil
				},
				resume: func(context.Context) (string, error) {
					events = append(events, "resume")
					resumed = true
					if tc.fail == "resume" {
						return "", errors.New("not ready")
					}
					return tc.after.RunningVersion, nil
				},
			}
			result, err := updateFrontDoorRuntime(context.Background(), ops)
			if tc.wantError == "" {
				if err != nil {
					t.Fatal(err)
				}
				if resumed && result != current {
					t.Fatalf("未返回已验证版本: %+v", result)
				}
			} else if err == nil || !strings.Contains(err.Error(), tc.wantError) {
				t.Fatalf("error=%v, want %q", err, tc.wantError)
			}
			if !reflect.DeepEqual(events, tc.wantEvents) {
				t.Fatalf("events=%v want=%v", events, tc.wantEvents)
			}
		})
	}
}

func TestFrontDoorRuntimeUpdateRechecksAfterLock(t *testing.T) {
	reads, stops := 0, 0
	_, err := updateFrontDoorRuntime(context.Background(), frontDoorUpdateOps{
		versions: func(context.Context) (CodexRuntimeVersions, error) {
			reads++
			if reads == 1 {
				return CodexRuntimeVersions{"0.161.0", "0.155.1", true}, nil
			}
			return CodexRuntimeVersions{"0.161.0", "0.161.0", false}, nil
		},
		lock:   func(context.Context) (func(), error) { return func() {}, nil },
		stop:   func(context.Context) error { stops++; return nil },
		resume: func(context.Context) (string, error) { t.Fatal("无需再次启动"); return "", nil },
	})
	if err != nil || stops != 0 {
		t.Fatalf("err=%v stops=%d", err, stops)
	}
}
