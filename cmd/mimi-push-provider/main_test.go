package main

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"testing"
	"time"
)

func TestServeUntilStoppedDrainsRequests(t *testing.T) {
	for _, tc := range []struct {
		name    string
		timeout time.Duration
		expire  bool
	}{
		{name: "delivered", timeout: 3 * time.Second},
		{name: "deadline", timeout: 100 * time.Millisecond, expire: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			listener, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			started, draining, deliver := make(chan struct{}), make(chan struct{}), make(chan struct{})
			server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				close(started)
				select {
				case <-deliver:
					_, _ = io.WriteString(w, "delivered")
				case <-r.Context().Done():
				}
			})}
			server.RegisterOnShutdown(func() { close(draining) })
			ctx, stop := context.WithCancel(context.Background())
			defer stop()
			defer server.Close()
			done := make(chan error, 1)
			go func() { done <- serveUntilStopped(ctx, server, listener, tc.timeout) }()
			clientResult := make(chan error, 1)
			go func() {
				client := &http.Client{Timeout: 5 * time.Second}
				response, err := client.Get("http://" + listener.Addr().String())
				if err == nil {
					defer response.Body.Close()
					var body []byte
					body, err = io.ReadAll(response.Body)
					if err == nil && string(body) != "delivered" {
						err = errors.New("missing delivery confirmation")
					}
				}
				clientResult <- err
			}()
			select {
			case <-started:
			case <-time.After(5 * time.Second):
				t.Fatal("handler did not start")
			}
			stop()
			select {
			case <-draining:
			case <-time.After(5 * time.Second):
				t.Fatal("server did not start draining")
			}
			if !tc.expire {
				close(deliver)
			}
			select {
			case err := <-done:
				if tc.expire && !errors.Is(err, context.DeadlineExceeded) || !tc.expire && err != nil {
					t.Fatalf("unexpected shutdown result: %v", err)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("server exceeded its shutdown budget")
			}
			if err := <-clientResult; (err != nil) != tc.expire {
				t.Fatalf("unexpected client result: %v", err)
			}
		})
	}
}
