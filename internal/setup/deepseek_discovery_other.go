//go:build !darwin

package setup

import "context"

func discoverDeepSeekLaunchAgent(context.Context) (deepSeekConnectionCandidate, error) {
	return deepSeekConnectionCandidate{}, errDeepSeekNotDiscovered
}

func currentDeepSeekLaunchAgentPID(context.Context) (int, error) {
	return 0, errDeepSeekNotDiscovered
}
