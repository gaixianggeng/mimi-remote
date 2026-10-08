//go:build darwin

package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestCodexFrontRuntimeRejectsUnsupportedConfig(t *testing.T) {
	for _, body := range []string{
		"{",
		`{"codex":{"enabled":false}}`,
		`{"app_server":{"transport":"ssh","ssh_target":"example.invalid"}}`,
		`{"app_server":{"transport":"local","ssh_target":"example.invalid"}}`,
	} {
		t.Run(body, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "config.json")
			if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
				t.Fatal(err)
			}
			for _, update := range []bool{false, true} {
				var output bytes.Buffer
				err := runCodexFrontRuntime([]string{"codex-front runtime", "--config", path, "--label", "test.mimi-codex-version"}, &output, update)
				if err == nil || output.Len() != 0 {
					t.Fatalf("不支持的配置不能返回成功: %v %s", err, output.String())
				}
			}
		})
	}
}
