//go:build windows

package windowslan

import (
	"context"
	"net"
	"os"
	"testing"
	"time"
)

// A native loopback socket checks table-class selection, byte order, image and
// access token without starting a service or requiring Windows elevation.
func TestTrustedLoopbackPeerUsesEstablishedSocket(t *testing.T) {
	l, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	conn, err := net.Dial("tcp4", l.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	server, err := l.Accept()
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if !TrustedPeer(ctx, conn, os.Getpid(), "") {
		t.Fatal("local test executable and user not recognized")
	}
	if TrustedPeer(ctx, conn, os.Getpid()+1, "") {
		t.Fatal("wrong expected PID accepted")
	}
}
