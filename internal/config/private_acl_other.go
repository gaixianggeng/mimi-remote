//go:build !windows && !linux && !darwin

package config

import "os"

func checkExtendedACL(*os.File) error          { return nil }
func repairExtendedACL(*os.File) error         { return nil }
func copyExtendedACL(*os.File, *os.File) error { return nil }
