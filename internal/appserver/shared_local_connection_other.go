//go:build !darwin

package appserver

import (
	"context"
	"net"
)

func (*SharedLocalTransport) validateConnectionSession(context.Context, net.Conn) error {
	return nil
}
