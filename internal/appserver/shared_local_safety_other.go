//go:build !linux && !darwin

package appserver

func validateSharedLocalSocketSafety(string) error {
	return nil
}
