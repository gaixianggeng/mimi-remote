package desktopipc

import (
	"os"
	"path/filepath"
	"testing"
)

func TestThreadHasLiveWriterReadsCodexLockDirectory(t *testing.T) {
	codexHome := t.TempDir()
	directory := writerLockDirForCodexHome(codexHome)
	if err := os.MkdirAll(directory, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "thread-held.lock"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	bridge, err := NewBridge(BridgeOptions{WriterLockDir: directory})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(bridge.Close)

	for _, testCase := range []struct {
		threadID string
		held     bool
		known    bool
	}{
		{threadID: "thread-held", held: true, known: true},
		{threadID: "thread-free", held: false, known: true},
		// 路径分隔符不能让探测逃出锁目录。
		{threadID: "../thread-held", held: false, known: false},
		{threadID: "", held: false, known: false},
	} {
		held, known := bridge.ThreadHasLiveWriter(testCase.threadID)
		if held != testCase.held || known != testCase.known {
			t.Fatalf("ThreadHasLiveWriter(%q) = (%t, %t), want (%t, %t)",
				testCase.threadID, held, known, testCase.held, testCase.known)
		}
	}
}

// 没有配置锁目录时必须回答“不知道”，让调用方退回原有的 owner 探测。
func TestThreadHasLiveWriterIsUnknownWithoutLockDirectory(t *testing.T) {
	bridge, err := NewBridge(BridgeOptions{})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(bridge.Close)
	if held, known := bridge.ThreadHasLiveWriter("thread-any"); held || known {
		t.Fatalf("ThreadHasLiveWriter without a lock directory = (%t, %t), want (false, false)", held, known)
	}
}
