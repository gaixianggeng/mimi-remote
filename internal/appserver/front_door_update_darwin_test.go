//go:build darwin

package appserver

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
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

func TestFrontDoorRuntimeVersionLegacyHomeCompatibility(t *testing.T) {
	home := shortSharedLocalCodexHome(t)
	otherHome := shortSharedLocalCodexHome(t)
	for _, tc := range []struct {
		name, reported      string
		required, wantError bool
	}{
		{"legacy default", "", false, false},
		{"isolated omission", "", true, true},
		{"wrong default home", otherHome, false, true},
		{"isolated match", home, true, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			socket := filepath.Join(home, "version.sock")
			listener, err := net.Listen("unix", socket)
			if err != nil {
				t.Fatal(err)
			}
			server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				upgrader := websocket.Upgrader{}
				conn, err := upgrader.Upgrade(w, r, nil)
				if err != nil {
					return
				}
				defer conn.Close()
				var request map[string]any
				if conn.ReadJSON(&request) != nil {
					return
				}
				_ = conn.WriteJSON(map[string]any{"id": request["id"], "result": map[string]any{
					"userAgent": "codex/0.149.1", "codexHome": tc.reported,
				}})
				_ = conn.ReadJSON(&request)
			})}
			go func() { _ = server.Serve(listener) }()
			defer server.Close()
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			version, err := frontDoorRuntimeVersion(ctx, socket, home, tc.required)
			if (err != nil) != tc.wantError || (!tc.wantError && version != "0.149.1") {
				t.Fatalf("version=%q err=%v", version, err)
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

func TestConfirmedRuntimeRestartFailureDoesNotStartReplacement(t *testing.T) {
	for _, failLock := range []bool{false, true} {
		t.Run(fmt.Sprint("lock=", failLock), func(t *testing.T) {
			unlocked, stopped := false, false
			_, err := updateFrontDoorRuntime(context.Background(), frontDoorUpdateOps{
				restart: true,
				versions: func(context.Context) (CodexRuntimeVersions, error) {
					return CodexRuntimeVersions{"0.161.0", "0.155.1", true}, nil
				},
				lock: func(context.Context) (func(), error) {
					if failLock {
						return nil, errors.New("locked")
					}
					return func() { unlocked = true }, nil
				},
				stop: func(context.Context) error { stopped = true; return errors.New("not exited") },
				resume: func(context.Context) (string, error) {
					t.Fatal("旧后台退出失败不能启动新版")
					return "", nil
				},
			})
			if err == nil || stopped == failLock || unlocked == failLock {
				t.Fatalf("err=%v stopped=%v unlocked=%v", err, stopped, unlocked)
			}
		})
	}
}
