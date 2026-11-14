package setup

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

// WorkspaceState contains only the two user-selected access roots, never credentials.
type WorkspaceState struct {
	ScanRoots   json.RawMessage `json:"scan_roots,omitempty"`
	BrowseRoots json.RawMessage `json:"browse_roots,omitempty"`
}

type WorkspaceConfigurationResult struct {
	Changed         bool           `json:"changed"`
	RestartRequired bool           `json:"restart_required"`
	Previous        WorkspaceState `json:"previous"`
	Applied         WorkspaceState `json:"applied"`
}

// ConfigureWorkspace changes explicit roots without resetting tokens, pairings or modules.
func ConfigureWorkspace(path, root string) (WorkspaceConfigurationResult, error) {
	if !filepath.IsAbs(root) {
		return WorkspaceConfigurationResult{}, fmt.Errorf("请选择完整的代码目录路径")
	}
	resolved, err := filepath.EvalSymlinks(root)
	if err != nil {
		return WorkspaceConfigurationResult{}, fmt.Errorf("无法打开代码目录：%w", err)
	}
	info, err := os.Stat(resolved)
	if err != nil || !info.IsDir() {
		return WorkspaceConfigurationResult{}, fmt.Errorf("代码目录必须是存在的文件夹")
	}
	doc, err := readModuleDocument(path, "network")
	if err != nil {
		return WorkspaceConfigurationResult{}, err
	}
	raw, err := json.Marshal([]string{filepath.Clean(resolved)})
	if err != nil {
		return WorkspaceConfigurationResult{}, err
	}
	return commitWorkspace(doc, WorkspaceState{ScanRoots: raw, BrowseRoots: raw})
}

func RestoreWorkspace(path string, previous WorkspaceConfigurationResult) (WorkspaceConfigurationResult, error) {
	doc, err := readModuleDocument(path, "network")
	if err != nil {
		return WorkspaceConfigurationResult{}, err
	}
	if !reflect.DeepEqual(workspaceState(doc), previous.Applied) {
		return WorkspaceConfigurationResult{}, fmt.Errorf("代码目录已被其他操作修改，未覆盖新的设置；请刷新后重试")
	}
	return commitWorkspace(doc, previous.Previous)
}

func workspaceState(doc moduleDocument) WorkspaceState {
	compact := func(raw json.RawMessage) json.RawMessage {
		if raw == nil {
			return nil
		}
		var buffer bytes.Buffer
		if err := json.Compact(&buffer, raw); err != nil {
			return raw
		}
		return buffer.Bytes()
	}
	return WorkspaceState{ScanRoots: compact(doc.document["scan_roots"]), BrowseRoots: compact(doc.document["browse_roots"])}
}

func commitWorkspace(doc moduleDocument, after WorkspaceState) (WorkspaceConfigurationResult, error) {
	before := workspaceState(doc)
	changed := !reflect.DeepEqual(before, after)
	if changed {
		for key, raw := range map[string]json.RawMessage{"scan_roots": after.ScanRoots, "browse_roots": after.BrowseRoots} {
			if raw == nil {
				delete(doc.document, key)
			} else {
				doc.document[key] = raw
			}
		}
		raw, err := json.MarshalIndent(doc.document, "", "  ")
		if err != nil {
			return WorkspaceConfigurationResult{}, err
		}
		if _, err := config.LoadSnapshot(raw); err != nil {
			return WorkspaceConfigurationResult{}, fmt.Errorf("新的目录配置无效：%w", err)
		}
		if err := writePrivateFileAtomicallyCAS(doc.path, doc.original, append(raw, '\n')); err != nil {
			return WorkspaceConfigurationResult{}, err
		}
	}
	return WorkspaceConfigurationResult{Changed: changed, RestartRequired: changed, Previous: before, Applied: after}, nil
}
