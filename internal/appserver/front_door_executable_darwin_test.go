//go:build darwin

package appserver

import "testing"

func TestMappedCodexExecutableRequiresUniqueProcessOwnedFile(t *testing.T) {
	for _, tc := range []struct{ name, output, want string }{
		{"mapped release", "p123\x00\nftxt\x00n/old-release/bin/codex\x00\nftxt\x00n/usr/lib/dyld\x00", "/old-release/bin/codex"},
		{"duplicate map", "p123\x00n/release/codex\x00n/release/codex\x00", "/release/codex"},
		{"arm64 archive", "p123\x00n/cask/codex-aarch64-apple-darwin\x00", "/cask/codex-aarch64-apple-darwin"},
		{"intel archive", "p123\x00n/cask/codex-x86_64-apple-darwin\x00", "/cask/codex-x86_64-apple-darwin"},
		{"unrelated executable", "p123\x00n/cask/codex-code-mode-host\x00", ""},
		{"wrong process", "p124\x00n/release/codex\x00", ""},
		{"missing owner", "n/release/codex\x00", ""},
		{"ambiguous", "p123\x00n/old/codex\x00n/new/codex\x00", ""},
		{"relative", "p123\x00ncodex\x00", ""},
		{"deleted", "p123\x00n/old/codex (deleted)\x00", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := mappedCodexExecutable([]byte(tc.output), 123)
			if tc.want == "" {
				if err == nil {
					t.Fatalf("不确定映射不能返回 %q", got)
				}
			} else if err != nil || got != tc.want {
				t.Fatalf("got=%q err=%v", got, err)
			}
		})
	}
}
