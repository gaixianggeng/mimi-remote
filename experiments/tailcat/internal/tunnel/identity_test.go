package tunnel

import (
	"path/filepath"
	"testing"

	"github.com/gaixianggeng/mimi-remote/experiments/tailcat/internal/privatefile"
)

// 第二次启动会重新读取已保存的身份。Windows 的 FileMode 恒为 0666，不能用
// POSIX 权限位拒绝自己刚写入的私有文件。
func TestPrivateFileWrittenByHostPassesPrivateFileCheck(t *testing.T) {
	path := filepath.Join(t.TempDir(), "host.private.json")
	if err := privatefile.Write(path, []byte("{}\n")); err != nil {
		t.Fatal(err)
	}
	if err := privatefile.Check(path); err != nil {
		t.Fatalf("a file written by writePrivateFile must be reusable: %v", err)
	}
}
