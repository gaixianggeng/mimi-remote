package main

import "testing"

func TestFormatReleaseVersion(t *testing.T) {
	tests := map[string]string{
		"0.3.7":  "v0.3.7",
		"v0.3.7": "v0.3.7",
		"V0.3.7": "v0.3.7",
		" dev ":  "开发版",
		"":       "开发版",
	}
	for input, want := range tests {
		if got := formatReleaseVersion(input); got != want {
			t.Fatalf("formatReleaseVersion(%q) = %q, want %q", input, got, want)
		}
	}
}
