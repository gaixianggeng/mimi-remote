//go:build !darwin && !linux

package sshbridge

import (
	"errors"
	"net"
)

type Server struct{}

func Listen(string, Options) (*Server, error) {
	return nil, errors.New("当前平台不支持 Mimi SSH 命令桥")
}
func (*Server) Close() error      { return nil }
func validatePeer(net.Conn) error { return errors.New("当前平台不支持 Unix peer 校验") }
