//go:build !windows

package main

func hideStandaloneManagedServiceConsole(_ []string) {}

func appendManagedServiceFailure(_ []string, _ error) {}
