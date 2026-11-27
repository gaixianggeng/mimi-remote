package main

import "strings"

// releaseVersion is injected by the platform packaging scripts from the same
// version value used for the installer and GitHub Release tag.
var releaseVersion = "dev"

// releasePublisherSHA256 is injected by scripts/build-windows-installer.ps1
// for signed Windows release builds (64-hex SHA-256 of the signing certificate's
// raw DER bytes). Unsigned and development builds leave it empty and fail closed.
var releasePublisherSHA256 = ""

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
