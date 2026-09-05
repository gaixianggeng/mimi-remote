//go:build linux

package main

import (
	"bufio"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/godbus/dbus/v5"
)

type testTrayWatcher struct{ registered chan string }

func (w *testTrayWatcher) RegisterStatusNotifierItem(name string) *dbus.Error {
	w.registered <- name
	return nil
}

func TestLinuxTraySessionLifecycle(t *testing.T) {
	path, err := exec.LookPath("dbus-daemon")
	if err != nil {
		t.Skip("dbus-daemon unavailable")
	}
	daemon := exec.Command(path, "--session", "--nofork", "--print-address=1")
	output, err := daemon.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err = daemon.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = daemon.Process.Kill(); _ = daemon.Wait() }()
	scanner := bufio.NewScanner(output)
	if !scanner.Scan() {
		t.Fatal("no session address")
	}
	t.Setenv("DBUS_SESSION_BUS_ADDRESS", scanner.Text())
	host, err := dbus.ConnectSessionBus()
	if err != nil {
		t.Fatal(err)
	}
	defer host.Close()
	watcher := &testTrayWatcher{registered: make(chan string, 4)}
	if err = host.Export(watcher, "/StatusNotifierWatcher", watcherInterface); err != nil {
		t.Fatal(err)
	}
	if _, err = host.RequestName(watcherInterface, dbus.NameFlagDoNotQueue); err != nil {
		t.Fatal(err)
	}
	agent := filepath.Join(t.TempDir(), "agentd")
	if err = os.WriteFile(agent, []byte(`#!/bin/sh
printf '%s\n' '{"version":"test","endpoint":"http://127.0.0.1:8787","process_ok":true,"service_ok":true,"doctor_ok":true}'
`), 0700); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- runLinuxTray(agent, false, false) }()
	defer func() { _ = quitLinuxTray(host) }()
	select {
	case <-watcher.registered:
	case err := <-done:
		t.Fatalf("tray stopped early: %v", err)
	case <-time.After(5 * time.Second):
		t.Fatal("tray did not register")
	}
	// Reopening from autostart must not create another instance or stop agentd.
	if err = runLinuxTray(agent, false, false); err != nil {
		t.Fatal(err)
	}
	var revision uint32
	var layout linuxMenuLayout
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err = host.Object(linuxTrayBusName, trayMenuPath).CallWithContext(ctx, trayMenuInterface+".GetLayout", 0, int32(0), int32(-1), []string{}).Store(&revision, &layout); err != nil {
		t.Fatal(err)
	}
	if len(layout.Children) == 0 {
		t.Fatal("host received empty menu")
	}
	// Replacing the watcher simulates a panel crash/restart within the same login.
	replacement, err := dbus.ConnectSessionBus()
	if err != nil {
		t.Fatal(err)
	}
	defer replacement.Close()
	nextWatcher := &testTrayWatcher{registered: make(chan string, 1)}
	if err = replacement.Export(nextWatcher, "/StatusNotifierWatcher", watcherInterface); err != nil {
		t.Fatal(err)
	}
	_, _ = host.ReleaseName(watcherInterface)
	if _, err = replacement.RequestName(watcherInterface, dbus.NameFlagDoNotQueue); err != nil {
		t.Fatal(err)
	}
	select {
	case <-nextWatcher.registered:
	case <-time.After(5 * time.Second):
		t.Fatal("watcher replacement did not re-register tray")
	}
	if err = quitLinuxTray(host); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("tray did not exit")
	}
	if err = quitLinuxTray(host); err != nil {
		t.Fatal("repeat quit must be harmless", err)
	}
}
