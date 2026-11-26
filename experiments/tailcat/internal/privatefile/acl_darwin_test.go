package privatefile

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestDarwinRejectsInheritedACLAndCreatesPrivateStage(t *testing.T) {
	dir := t.TempDir()
	if output, err := exec.Command("/bin/chmod", "+a", "everyone allow read,file_inherit", dir).CombinedOutput(); err != nil {
		t.Fatalf("set parent ACL: %v %s", err, output)
	}
	path := filepath.Join(dir, "inherited")
	if err := os.WriteFile(path, []byte("original"), 0600); err != nil {
		t.Fatal(err)
	}
	assertRefusesNoncanonicalFile(t, path)
	if err := Write(filepath.Join(dir, "new"), []byte("private")); err != nil {
		t.Fatal(err)
	}
}
