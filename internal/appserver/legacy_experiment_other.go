//go:build !darwin

package appserver

func LegacyCodexExperimentResidue() (string, error) {
	return "", nil
}
