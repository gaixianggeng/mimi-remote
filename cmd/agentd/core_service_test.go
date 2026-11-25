package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"runtime"
	"sync/atomic"
	"testing"
	"time"
)

func fakeCoreManager(t *testing.T, owner string, submit func(string, string) error) {
	t.Helper()
	oldPeer, oldSubmit := inspectCorePeer, submitCoreAction
	t.Cleanup(func() { inspectCorePeer, submitCoreAction = oldPeer, oldSubmit })
	var pid atomic.Int32
	pid.Store(1)
	inspectCorePeer = func(context.Context, string, net.Conn) (coreServiceOwner, error) {
		if owner == "" {
			return coreServiceOwner{}, errUnknownCoreOwner
		}
		return coreServiceOwner{manager: owner, pid: int(pid.Load())}, nil
	}
	submitCoreAction = func(_ context.Context, _ string, own, action string, _, _ io.Writer) error {
		if err := submit(own, action); err != nil {
			return err
		}
		pid.Add(1)
		return nil
	}
}

func TestCoreStartReusesOnlyAuthenticatedManagedListener(t *testing.T) {
	const token = "owned-fixture-bearer"
	for _, tc := range []struct {
		name, platform, owner, clientToken, serverVersion string
		wantOK, getsCredential                            bool
	}{
		{"GUI", "darwin", "gui", token, "1.2.3", true, true},
		{"Homebrew", "darwin", "homebrew", token, "1.2.3", true, true},
		{"systemd", "linux", "systemd", token, "1.2.3", true, true},
		{"scheduled task", "windows", "scheduled-task", token, "1.2.3", true, true},
		{"unmanaged listener", "darwin", "", token, "1.2.3", false, false},
		{"wrong credential", "linux", "systemd", "wrong", "1.2.3", false, true},
		{"old daemon", "darwin", "homebrew", token, "1.2.2", false, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var requests atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				requests.Add(1)
				if r.URL.Path != "/api/readyz" {
					t.Error("unexpected path", r.URL.Path)
					http.NotFound(w, r)
					return
				}
				if r.Header.Get("Authorization") != "Bearer "+token {
					http.Error(w, "unauthorized", http.StatusUnauthorized)
					return
				}
				fmt.Fprintf(w, "{\"ok\":true,\"version\":%q}", tc.serverVersion)
			}))
			defer server.Close()
			fakeCoreManager(t, tc.owner, func(string, string) error {
				t.Error("unexpected manager mutation")
				return errors.New("unexpected submit")
			})
			err := manageCoreService(context.Background(), tc.platform, "start", server.URL, tc.clientToken, "1.2.3", time.Second, io.Discard, io.Discard)
			if (err == nil) != tc.wantOK || (requests.Load() > 0) != tc.getsCredential {
				t.Fatalf("err=%v requests=%d", err, requests.Load())
			}
		})
	}
}

func TestCoreRestartUsesCurrentOwnerAndRequiresNewReadiness(t *testing.T) {
	for _, tc := range []struct {
		name   string
		repair bool
	}{{"success", true}, {"still mismatched", false}} {
		t.Run(tc.name, func(t *testing.T) {
			var restarted atomic.Bool
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get("Authorization") != "Bearer current" || !restarted.Load() || !tc.repair {
					w.WriteHeader(http.StatusUnauthorized)
					return
				}
				io.WriteString(w, "{\"ok\":true,\"version\":\"1.2.3\"}")
			}))
			defer server.Close()
			fakeCoreManager(t, "gui", func(owner, action string) error {
				if owner != "gui" || action != "restart" || !restarted.CompareAndSwap(false, true) {
					t.Fatalf("wrong service mutation %s %s", owner, action)
				}
				return nil
			})
			err := manageCoreService(context.Background(), "darwin", "restart", server.URL, "current", "1.2.3", time.Second, io.Discard, io.Discard)
			if !restarted.Load() || (err == nil) != tc.repair {
				t.Fatalf("restart=%v err=%v", restarted.Load(), err)
			}
		})
	}
}

func TestStartWaitsForPendingSocketOwnershipWithoutSubmitting(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		if r.Header.Get("Authorization") != "Bearer fixture" {
			t.Error("missing bearer on verified connection")
		}
		io.WriteString(w, `{"ok":true,"version":"1"}`)
	}))
	defer server.Close()
	fakeCoreManager(t, "systemd", func(string, string) error {
		t.Fatal("submitted start for a bound listener")
		return nil
	})
	attempts := 0
	inspectCorePeer = func(context.Context, string, net.Conn) (coreServiceOwner, error) {
		attempts++
		if attempts == 1 {
			return coreServiceOwner{}, errCoreOwnerPending
		}
		return coreServiceOwner{manager: "systemd", pid: 42}, nil
	}
	if err := manageCoreService(t.Context(), "linux", "start", server.URL, "fixture", "1", time.Second, io.Discard, io.Discard); err != nil || requests.Load() != 1 {
		t.Fatalf("start err=%v requests=%d", err, requests.Load())
	}
}

func TestCoreColdStartRequiresBoundExpectedOwner(t *testing.T) {
	for _, owner := range []string{"systemd", "", "gui"} {
		t.Run("after startup "+owner, func(t *testing.T) {
			// A bound, not-yet-listening TCP address is unavailable in the standard
			// library. Reserve an ephemeral port until immediately before the command.
			reservation, err := net.Listen("tcp4", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			address := reservation.Addr().String()
			reservation.Close()
			var submitted bool
			fakeCoreManager(t, owner, func(previous, action string) error {
				if previous != "systemd" || action != "start" || submitted {
					t.Fatal(previous, action)
				}
				submitted = true
				l, err := net.Listen("tcp4", address)
				if err != nil {
					return err
				}
				s := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					if r.Header.Get("Authorization") != "Bearer fixture" {
						w.WriteHeader(http.StatusUnauthorized)
						return
					}
					io.WriteString(w, "{\"ok\":true,\"version\":\"1.2.3\"}")
				})}
				go s.Serve(l)
				t.Cleanup(func() { s.Close() })
				return nil
			})
			err = manageCoreService(context.Background(), "linux", "start", "http://"+address, "fixture", "1.2.3", time.Second, io.Discard, io.Discard)
			if !submitted || (err == nil) != (owner == "systemd") {
				t.Fatalf("submitted=%v err=%v", submitted, err)
			}
		})
	}
}

func TestLsofCoreOwnerMatchesServerHalf(t *testing.T) {
	client := netip.MustParseAddrPort("127.0.0.1:30251")
	server := netip.MustParseAddrPort("127.0.0.1:8787")
	output := "p12\nn127.0.0.1:30251->127.0.0.1:8787\np14\nn127.0.0.1:8787->127.0.0.1:10000\np21\nn[::ffff:127.0.0.1]:8787->[::ffff:127.0.0.1]:30251\n"
	if got := lsofPeerPID(output, server, client); got != 21 {
		t.Fatal(got)
	}
}

func TestNativeUnixCorePeerMatchesManagerPID(t *testing.T) {
	if runtime.GOOS != "darwin" && runtime.GOOS != "linux" {
		t.Skip("Unix process inspection")
	}
	dir := t.TempDir()
	if runtime.GOOS == "linux" {
		if err := os.WriteFile(filepath.Join(dir, "systemctl"), []byte(fmt.Sprintf("#!/bin/sh\nprintf '%%s\\n' %d\n", os.Getpid())), 0700); err != nil {
			t.Fatal(err)
		}
	} else {
		script := fmt.Sprintf("#!/bin/sh\ncase \"$2\" in */%s) printf '\\tpid = %%s\\n' %d ;; *) echo 'Could not find service' >&2; exit 113 ;; esac\n", homebrewServiceLabel, os.Getpid())
		if err := os.WriteFile(filepath.Join(dir, "launchctl"), []byte(script), 0700); err != nil {
			t.Fatal(err)
		}
	}
	oldL, oldS := coreLaunchctl, coreSystemctl
	coreLaunchctl, coreSystemctl = filepath.Join(dir, "launchctl"), filepath.Join(dir, "systemctl")
	t.Cleanup(func() { coreLaunchctl, coreSystemctl = oldL, oldS })
	t.Setenv("PATH", t.TempDir())
	l, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	c, err := net.Dial("tcp4", l.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	accepted, err := l.Accept()
	if err != nil {
		t.Fatal(err)
	}
	defer accepted.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	owner, err := platformCorePeer(ctx, runtime.GOOS, c)
	if err != nil || owner.manager == "" {
		t.Fatalf("managed peer: owner=%+v err=%v", owner, err)
	}
}

func TestColdMacStartRespectsRegisteredManagers(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("launchctl fixture uses Unix shell")
	}
	for _, tc := range []struct {
		name, brew, gui, manager string
		active, conflict         bool
	}{
		{"Homebrew starting", "33", "0", "homebrew", true, false},
		{"GUI starting", "0", "42", "gui", true, false},
		{"both active", "33", "42", "", false, true},
		{"both idle", "0", "0", "", false, true},
		{"GUI registered", "", "0", "gui", false, false},
		{"Homebrew registered", "0", "", "homebrew", false, false},
		{"no jobs", "", "", "homebrew", false, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "launchctl")
			// Empty PID means no registration, zero means a registered idle job.
			helper := "#!/bin/sh\ncase \"$2\" in */" + homebrewServiceLabel + ") agreed=\"$MIMI_BREW_PID\" ;; */" + guiAgentLabel + ") agreed=\"$MIMI_GUI_PID\" ;; *) exit 2 ;; esac\nif [ -z \"$agreed\" ]; then echo 'Could not find service' >&2; exit 113; fi\nprintf '\\tpid = %s\\n' \"$agreed\"\n"
			if err := os.WriteFile(path, []byte(helper), 0700); err != nil {
				t.Fatal(err)
			}
			old := coreLaunchctl
			coreLaunchctl = path
			t.Cleanup(func() { coreLaunchctl = old })
			t.Setenv("MIMI_BREW_PID", tc.brew)
			t.Setenv("MIMI_GUI_PID", tc.gui)
			t.Setenv("PATH", t.TempDir())
			var submits int
			fakeCoreManager(t, "", func(owner, action string) error {
				if owner != tc.manager || action != "start" {
					t.Fatal(owner, action)
				}
				submits++
				return nil
			})
			err := manageCoreService(context.Background(), "darwin", "start", "http://"+unusedCoreTestAddress(t), "fixture", "1", 0, io.Discard, io.Discard)
			if (err != nil) != tc.conflict || submits > 1 || (submits == 1) != (!tc.active && !tc.conflict) {
				t.Fatalf("submits=%d err=%v", submits, err)
			}
		})
	}
}
