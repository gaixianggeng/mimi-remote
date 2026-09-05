package main

import "strings"

// releaseVersion is injected by the platform packaging scripts from the same
// version value used for the installer and GitHub Release tag.
var releaseVersion = "dev"

func formatReleaseVersion(value string) string {
	value = strings.TrimSpace(value)
	if value == "" || strings.EqualFold(value, "dev") {
		return "开发版"
	}
	value = strings.TrimPrefix(value, "v")
	value = strings.TrimPrefix(value, "V")
	if value == "" {
		return "开发版"
	}
	return "v" + value
}
