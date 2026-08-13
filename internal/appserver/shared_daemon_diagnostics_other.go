//go:build !darwin

package appserver

import "context"

func InspectSharedDaemonDiagnostics(
	context.Context,
	LocalDaemonOptions,
) (SharedDaemonDiagnostics, error) {
	return SharedDaemonDiagnostics{
		Supported:     false,
		OwnerState:    SharedDaemonOwnerStateUnknown,
		ResourceState: SharedDaemonResourceStateUnknown,
	}, nil
}
