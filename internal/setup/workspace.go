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

type WorkspaceSelection struct {
	ScanRoot, BrowseRoot string
	// PrimaryOnly edits the first entry of each supplied list, preserving its other grants.
	PrimaryOnly bool
}

func ConfigureWorkspace(path, root string) (WorkspaceConfigurationResult, error) {
	return ConfigureWorkspaceRoots(path, root, root)
}
func ConfigureWorkspaceRoots(path, scan, browse string) (WorkspaceConfigurationResult, error) {
	if scan == "" {
		return WorkspaceConfigurationResult{}, saveFailure("invalid_request", errors.New("请选择代码目录"))
	}
	return EditWorkspace(path, "", WorkspaceSelection{ScanRoot: scan, BrowseRoot: browse}, nil)
}
func RestoreWorkspace(path string, prior WorkspaceConfigurationResult) (WorkspaceConfigurationResult, error) {
	return EditWorkspace(path, "", WorkspaceSelection{}, &prior)
}
func EditWorkspace(path, legacy string, selection WorkspaceSelection, restore *WorkspaceConfigurationResult) (WorkspaceConfigurationResult, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	path, err := resolveConfigPath(path)
	if err != nil {
		return WorkspaceConfigurationResult{}, err
	}
	if err = recoverPublication(ctx, path, legacy, defaultSetupFileTransactionOps(), nil); err != nil {
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
		if selection.ScanRoot == "" && selection.BrowseRoot == "" {
			return WorkspaceConfigurationResult{}, saveFailure("invalid_request", errors.New("请选择代码目录"))
		}
		if err := p.editRootList("scan_roots", p.cfg.ScanRoots, selection.ScanRoot, selection.PrimaryOnly); err != nil {
			return WorkspaceConfigurationResult{}, err
		}
		if err := p.editRootList("browse_roots", p.cfg.BrowseRoots, selection.BrowseRoot, selection.PrimaryOnly); err != nil {
			return WorkspaceConfigurationResult{}, err
		}
		if selection.ScanRoot != "" {
			p.set(true, "onboarding", "workspace_confirmed")
		}
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

func (p *proposal) editRootList(key string, prior []string, selected string, primaryOnly bool) error {
	roots := prior
	if selected != "" {
		roots = []string{selected}
		if primaryOnly && len(prior) > 1 {
			roots = append(roots, prior[1:]...)
		}
	}
	for i, root := range roots {
		d, err := inspectSelection(root)
		if err != nil {
			return err
		}
		p.roots = append(p.roots, d)
		if i == 0 && selected != "" {
			roots[0] = d.resolved
		}
	}
	if selected != "" {
		p.set(roots, key)
	}
	return nil
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
