package cliinspect

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

const helperFlag = "-test.run=^TestInspectionHelper$"

func TestInspectionHelper(t *testing.T) {
	args := os.Args
	if len(args) < 4 || args[1] != helperFlag || args[2] != "--" {
		return
	}
	mode := args[3]
	if mode == "child" {
		conn, err := net.Dial("tcp", args[4])
		if err != nil {
			t.Fatal(err)
		}
		ready, err := net.Dial("tcp", args[5])
		if err != nil {
			t.Fatal(err)
		}
		ready.Close()
		// The test closes its connection on failure so even a leaking child exits.
		io.Copy(io.Discard, conn)
		os.Exit(0)
	}
	ready, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	child := exec.Command(os.Args[0], helperFlag, "--", "child", args[4], ready.Addr().String())
	if mode == "inherited-output" {
		child.Stdout = os.Stdout
	}
	if err := child.Start(); err != nil {
		t.Fatal(err)
	}
	conn, err := ready.Accept()
	if err != nil {
		t.Fatal(err)
	}
	conn.Close()
	ready.Close()
	if mode == "timeout" {
		time.Sleep(time.Minute)
	}
	fmt.Println("codex-cli 0.155.0")
	os.Exit(0)
}

func TestInspectionCleansDescendants(t *testing.T) {
	for _, mode := range []string{"closed-output", "inherited-output", "timeout"} {
		t.Run(mode, func(t *testing.T) {
			listener, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()
			budget := 10 * time.Second
			if mode == "timeout" {
				budget = 4 * time.Second
			}
			ctx, cancel := context.WithTimeout(context.Background(), budget)
			defer cancel()
			deadline, _ := ctx.Deadline()
			listener.SetDeadline(deadline)
			done := make(chan error, 1)
			go func() {
				// Avoid the race detector's one-second exit delay in the helper.
				env := append(os.Environ(), "GORACE=atexit_sleep_ms=0")
				output, err := Run(ctx, os.Args[0], env, helperFlag, "--", mode, listener.Addr().String())
				if err == nil && strings.TrimSpace(output) != "codex-cli 0.155.0" {
					err = errors.New("missing shim version")
				}
				done <- err
			}()
			conn, err := listener.Accept()
			if err != nil {
				t.Fatal(err)
			}
			defer conn.Close()
			err = <-done
			if mode == "timeout" && !errors.Is(err, context.DeadlineExceeded) || mode != "timeout" && err != nil {
				t.Fatalf("inspection result: %v", err)
			}
			conn.SetReadDeadline(time.Now().Add(2 * time.Second))
			// Forced teardown can close the socket with EOF or a reset on Windows.
			n, err := conn.Read(make([]byte, 1))
			var netErr net.Error
			if n != 0 || err == nil || errors.As(err, &netErr) && netErr.Timeout() {
				t.Fatalf("child connection still open after cleanup: %v", err)
			}
		})
	}
}
