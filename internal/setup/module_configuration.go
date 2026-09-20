package setup

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

type moduleDocument struct {
	path     string
	original []byte
	document map[string]json.RawMessage
	section  map[string]json.RawMessage
	cfg      config.Config
}

func readModuleDocument(path, section string) (moduleDocument, error) {
	resolved, err := resolveConfigPath(path)
	if err != nil {
		return moduleDocument{}, err
	}
	info, err := os.Lstat(resolved)
	if err != nil {
		return moduleDocument{}, err
	}
	if !info.Mode().IsRegular() {
		return moduleDocument{}, fmt.Errorf("配置必须是普通文件，不能是符号链接")
	}
	raw, err := os.ReadFile(resolved)
	if err != nil {
		return moduleDocument{}, err
	}
	cfg, err := config.LoadSnapshot(raw)
	if err != nil {
		return moduleDocument{}, err
	}
	result := moduleDocument{path: resolved, original: raw, cfg: cfg}
	if err := json.Unmarshal(raw, &result.document); err != nil {
		return moduleDocument{}, err
	}
	if result.document == nil {
		return moduleDocument{}, fmt.Errorf("配置必须是 JSON object")
	}
	result.section = map[string]json.RawMessage{}
	if value, ok := result.document[section]; ok && string(value) != "null" {
		if err := json.Unmarshal(value, &result.section); err != nil {
			return moduleDocument{}, err
		}
	}
	return result, nil
}

func (d moduleDocument) commit(section string, fields map[string]any) error {
	for key, value := range fields {
		if value == nil {
			delete(d.section, key)
			continue
		}
		raw, err := json.Marshal(value)
		if err != nil {
			return err
		}
		d.section[key] = raw
	}
	rawSection, err := json.Marshal(d.section)
	if err != nil {
		return err
	}
	d.document[section] = rawSection
	raw, err := json.MarshalIndent(d.document, "", "  ")
	if err != nil {
		return err
	}
	if _, err := config.LoadSnapshot(raw); err != nil {
		return fmt.Errorf("新的模块配置无效：%w", err)
	}
	return writePrivateFileAtomicallyCAS(d.path, d.original, append(raw, '\n'))
}

func optionalBoolValue(value *bool) any {
	if value == nil {
		return nil
	}
	return *value
}
