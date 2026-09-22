//go:build !darwin

package appserver

import (
	"context"

	"github.com/gorilla/websocket"
)

// SharedLocalSessionError 只会由 macOS 登录会话探针返回。
type SharedLocalSessionError struct {
	Kind string
	Err  error
}

func (e *SharedLocalSessionError) Error() string {
	return "共享本机会话探针失败"
}

func (e *SharedLocalSessionError) Unwrap() error {
	if e == nil {
		return nil
	}
	return e.Err
}

func validateSharedLocalSession(context.Context, *websocket.Conn) error {
	return nil
}
