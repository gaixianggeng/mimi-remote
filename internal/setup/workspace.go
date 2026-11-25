package setup

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"reflect"
	"time"
)

type WorkspaceState struct {
	ScanRoots   json.RawMessage `json:"scan_roots,omitempty"`
	BrowseRoots json.RawMessage `json:"browse_roots,omitempty"`
	Confirmed   json.RawMessage `json:"workspace_confirmed,omitempty"`
}
type WorkspaceConfigurationResult struct {
	Changed         bool           `json:"changed"`
	RestartRequired bool           `json:"restart_required"`
	Previous        WorkspaceState `json:"previous"`
	Applied         WorkspaceState `json:"applied"`
}

func ConfigureWorkspace(path, root string) (WorkspaceConfigurationResult, error) {
	return ConfigureWorkspaceRoots(path, root, root)
}
func ConfigureWorkspaceRoots(path, scan, browse string) (WorkspaceConfigurationResult, error) {
	return EditWorkspace(path, "", scan, browse, nil)
}
func RestoreWorkspace(path string, prior WorkspaceConfigurationResult) (WorkspaceConfigurationResult, error) {
	return EditWorkspace(path, "", "", "", &prior)
}
func EditWorkspace(path, legacy, scan, browse string, restore *WorkspaceConfigurationResult) (WorkspaceConfigurationResult, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	path, err := resolveConfigPath(path)
	if err != nil {
		return WorkspaceConfigurationResult{}, err
	}
	if err = recoverPublication(ctx, path, defaultSetupFileTransactionOps(), nil); err != nil {
		return WorkspaceConfigurationResult{}, err
	}
	p, err := readProposal(path, legacy, false)
	if err != nil {
		return WorkspaceConfigurationResult{}, err
	}
	if !p.source.exists {
		return WorkspaceConfigurationResult{}, saveFailure("config_missing", os.ErrNotExist)
	}
	before := workspaceState(p.doc)
	if restore != nil {
		if !reflect.DeepEqual(before, compactWorkspaceState(restore.Applied)) {
			return WorkspaceConfigurationResult{}, saveFailure("config_concurrent_change", errors.New("代码目录已更改，请刷新后重试"))
		}
		prev := restore.Previous
		for key, raw := range map[string]json.RawMessage{"scan_roots": prev.ScanRoots, "browse_roots": prev.BrowseRoots} {
			var roots []string
			if raw == nil {
				p.set(nil, key)
				continue
			}
			if err = json.Unmarshal(raw, &roots); err != nil {
				return WorkspaceConfigurationResult{}, saveFailure("invalid_request", err)
			}
			for _, r := range roots {
				d, err := inspectSelection(r)
				if err != nil {
					return WorkspaceConfigurationResult{}, err
				}
				p.roots = append(p.roots, d)
			}
			p.set(raw, key)
		}
		if prev.Confirmed == nil {
			p.set(nil, "onboarding", "workspace_confirmed")
		} else {
			p.set(prev.Confirmed, "onboarding", "workspace_confirmed")
		}
	} else {
		if scan == "" {
			return WorkspaceConfigurationResult{}, saveFailure("invalid_request", errors.New("请选择代码目录"))
		}
		for _, c := range []struct{ key, root string }{{"scan_roots", scan}, {"browse_roots", browse}} {
			if c.root == "" {
				for _, prior := range p.cfg.BrowseRoots {
					d, err := inspectSelection(prior)
					if err != nil {
						return WorkspaceConfigurationResult{}, err
					}
					p.roots = append(p.roots, d)
				}
				continue
			}
			d, err := inspectSelection(c.root)
			if err != nil {
				return WorkspaceConfigurationResult{}, err
			}
			p.roots = append(p.roots, d)
			p.set([]string{d.resolved}, c.key)
		}
		p.set(true, "onboarding", "workspace_confirmed")
	}
	raw, err := p.bytes()
	if err != nil {
		return WorkspaceConfigurationResult{}, err
	}
	if _, err = p.commit(ctx, raw, defaultSetupFileTransactionOps()); err != nil {
		return WorkspaceConfigurationResult{}, err
	}
	return WorkspaceConfigurationResult{p.changed, p.changed, before, workspaceState(p.doc)}, nil
}
func workspaceState(doc setupDocument) WorkspaceState {
	var section setupDocument
	_ = json.Unmarshal(doc[doc.spelling("onboarding")], &section)
	return compactWorkspaceState(WorkspaceState{doc[doc.spelling("scan_roots")], doc[doc.spelling("browse_roots")], section[section.spelling("workspace_confirmed")]})
}
func compactWorkspaceState(s WorkspaceState) WorkspaceState {
	compact := func(raw json.RawMessage) json.RawMessage {
		if raw == nil {
			return nil
		}
		var b bytes.Buffer
		if json.Compact(&b, raw) != nil {
			return raw
		}
		return b.Bytes()
	}
	return WorkspaceState{compact(s.ScanRoots), compact(s.BrowseRoots), compact(s.Confirmed)}
}
