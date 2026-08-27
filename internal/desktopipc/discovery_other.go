//go:build !darwin

package desktopipc

func inspectDesktop(string, map[string]string) (DesktopInfo, error) {
	return DesktopInfo{}, nil
}

func desktopRunning() (bool, error) { return false, nil }
