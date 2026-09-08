package httpapi

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestGitStatusPinsPatchPrefixesWhenMnemonicPrefixesAreConfigured(t *testing.T) {
	requireGit(t)
	repo := newCommittedGitRepo(t)
	runGitTestCommand(t, repo, "config", "diff.mnemonicPrefix", "true")

	baseLines := numberedLines("line", 20)
	if err := os.WriteFile(filepath.Join(repo, "README.md"), []byte(strings.Join(baseLines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGitTestCommand(t, repo, "add", "README.md")
	runGitTestCommand(t, repo, "commit", "-m", "baseline lines")
	baseLines[1] = "changed 2"
	baseLines[17] = "changed 18"
	if err := os.WriteFile(filepath.Join(repo, "README.md"), []byte(strings.Join(baseLines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.Projects = []config.ProjectConfig{{ID: "repo", Name: "Repo", Path: repo}}
	})
	status, err := server.router.gitStatus(context.Background(), repo)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(status.UnstagedDiff, "diff --git a/README.md b/README.md") {
		t.Fatalf("Git diff 必须覆盖用户 mnemonic prefix，got=%q", status.UnstagedDiff)
	}
	patches := splitGitDiffIntoSingleHunkPatches(t, status.UnstagedDiff)
	if len(patches) != 2 {
		t.Fatalf("测试 diff 应拆出两个 hunk，got=%d patches=%q", len(patches), patches)
	}
	if _, err := normalizedGitPatch(patches[0]); err != nil {
		t.Fatalf("后端生成的单 hunk patch 必须通过安全校验：%v", err)
	}
	legacyMnemonicPatch := strings.NewReplacer(
		"diff --git a/", "diff --git i/",
		" b/", " w/",
		"--- a/", "--- i/",
		"+++ b/", "+++ w/",
	).Replace(patches[0])
	if _, err := normalizedGitPatch(legacyMnemonicPatch); err != nil {
		t.Fatalf("旧客户端回传的 mnemonic-prefix patch 也必须通过安全校验：%v", err)
	}
}
