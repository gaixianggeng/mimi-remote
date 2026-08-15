//go:build !darwin

package appserver

import (
	"context"
	"fmt"
)

var sharedDaemonValidateSignedRuntime = validateSignedSharedDaemonRuntime

func validateSignedSharedDaemonRuntime(
	context.Context,
	LocalDaemonOptions,
	string,
) error {
	return fmt.Errorf("签名 node supervisor 仅支持 macOS")
}
