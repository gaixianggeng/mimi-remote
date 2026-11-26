//go:build !darwin

package config

func repairInaccessibleFile(_ string, openErr error, _ repairTargetCheck) (bool, error) {
	return false, openErr
}
