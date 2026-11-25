package setup

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

type selectedDirectory struct {
	path, resolved string
	info           os.FileInfo
}

func inspectSelection(path string) (selectedDirectory, error) {
	path = config.ExpandPath(path)
	if !filepath.IsAbs(path) {
		return selectedDirectory{}, saveFailure("invalid_request", errors.New("请选择绝对路径"))
	}
	if _, code := config.InspectWorkspaceRoot(path); code != "" {
		return selectedDirectory{}, &SaveError{Code: code, Step: "workspace_root", Cause: errors.New("请重新选择代码目录")}
	}
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return selectedDirectory{}, &SaveError{Code: "workspace_unreadable", Step: "workspace_root", Cause: err}
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return selectedDirectory{}, &SaveError{Code: "workspace_unreadable", Step: "workspace_root", Cause: err}
	}
	return selectedDirectory{path, resolved, info}, nil
}
func (p *proposal) selectRoots(o Options) error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	scan, _ := proposedRoot(o.ScanRoot, p.cfg.ScanRoots, filepath.Join(home, "code"))
	browse, _ := proposedRoot(o.BrowseRoot, p.cfg.BrowseRoots, scan)
	choices := []struct {
		key, root, explicit string
		prior               []string
	}{
		{"scan_roots", scan, o.ScanRoot, p.cfg.ScanRoots}, {"browse_roots", browse, o.BrowseRoot, p.cfg.BrowseRoots},
	}
	for _, c := range choices {
		roots := c.prior
		replace := len(c.prior) == 0
		if c.explicit != "" && !replace {
			// Echoing the preview must preserve additional existing grants.
			first, e1 := filepath.EvalSymlinks(config.ExpandPath(c.prior[0]))
			selected, e2 := filepath.EvalSymlinks(config.ExpandPath(c.explicit))
			replace = e1 != nil || e2 != nil || first != selected
		}
		if replace {
			roots = []string{c.root}
		}
		for _, root := range roots {
			root = config.ExpandPath(root)
			if !filepath.IsAbs(root) {
				return saveFailure("invalid_request", errors.New("请选择绝对路径"))
			}
			if o.CreateRoot && c.explicit != "" && root == config.ExpandPath(c.explicit) {
				if _, err := os.Stat(root); errors.Is(err, os.ErrNotExist) {
					if err = os.MkdirAll(root, 0700); err != nil {
						return &SaveError{Code: "workspace_unreadable", Step: "workspace_root", Cause: err}
					}
				}
			}
			directory, err := inspectSelection(root)
			if err != nil {
				return err
			}
			p.roots = append(p.roots, directory)
			if replace {
				p.set([]string{directory.resolved}, c.key)
			}
		}
	}
	if !p.source.exists {
		p.set(!o.PendingWorkspace, "onboarding", "workspace_confirmed")
	} else if o.SaveOnly && !o.PendingWorkspace && (o.ScanRoot != "" || o.BrowseRoot != "") {
		p.set(true, "onboarding", "workspace_confirmed")
	}
	return nil
}

func runWithFileOps(ctx context.Context, o Options, ops setupFileTransactionOps) (Result, error) {
	path, err := resolveConfigPath(o.ConfigPath)
	if err != nil {
		return Result{}, err
	}
	var identity interruptedIdentity
	if err = recoverPublication(ctx, path, ops, &identity); err != nil {
		return Result{}, err
	}
	p, err := readProposal(path, o.LegacyPath, o.Force)
	if err != nil {
		return Result{}, err
	}
	if err := ctx.Err(); err != nil {
		return Result{}, err
	}
	if !p.source.exists {
		if o.RequireExisting {
			return Result{}, saveFailure("config_missing", os.ErrNotExist)
		}
		if err = p.fresh(o, identity); err != nil {
			return Result{}, saveFailure("config_commit_failed", err)
		}
	}
	if !p.source.exists || o.SaveOnly {
		if err = p.selectRoots(o); err != nil {
			return Result{}, err
		}
		if err = p.applyAssistants(ctx, o); err != nil {
			return Result{}, err
		}
	}
	raw, err := p.bytes()
	if err != nil {
		return Result{}, err
	}
	cfg, err := p.commit(ctx, raw, ops)
	if err != nil {
		return Result{}, err
	}
	r := localServiceResult(path, cfg)
	if !o.SaveOnly && !o.LocalServiceOnly {
		r, err = ResultFromConfigForNetwork(ctx, path, cfg, PairingNetworkAuto)
		if err != nil {
			return Result{}, err
		}
	}
	r.Created = !p.source.exists
	r.Migrated = p.source.exists && !p.dest.exists
	if len(cfg.ScanRoots) > 0 {
		r.ScanRoot = cfg.ScanRoots[0]
	}
	if len(cfg.BrowseRoots) > 0 {
		r.BrowseRoot = cfg.BrowseRoots[0]
	}
	r.AppServerSSHTarget = cfg.AppServer.SSHTarget
	return r, nil
}
func (p *proposal) check(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	for _, s := range []configImage{p.dest, p.legacy} {
		if err := s.check(); err != nil {
			return err
		}
	}
	if p.referencedToken.exists {
		if err := p.referencedToken.check(); err != nil {
			return err
		}
	}
	for _, d := range p.roots {
		now, err := inspectSelection(d.path)
		if err != nil {
			return err
		}
		if now.resolved != d.resolved || !os.SameFile(now.info, d.info) {
			return &SaveError{Code: "config_concurrent_change", Step: "config_store", Cause: errors.New("所选目录已替换，请重新选择")}
		}
	}
	return nil
}

type RuntimePathResult struct {
	Changed         bool `json:"changed"`
	RestartRequired bool `json:"restart_required"`
}

func ConfigureRuntimePaths(path, legacy string, pins map[string]string) (RuntimePathResult, error) {
	resolved, err := resolveConfigPath(path)
	if err != nil {
		return RuntimePathResult{}, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err = recoverPublication(ctx, resolved, defaultSetupFileTransactionOps(), nil); err != nil {
		return RuntimePathResult{}, err
	}
	p, err := readProposal(resolved, legacy, false)
	if err != nil {
		return RuntimePathResult{}, err
	}
	if !p.source.exists {
		return RuntimePathResult{}, saveFailure("config_missing", os.ErrNotExist)
	}
	for id, value := range pins {
		if err = p.applyPin(id, value); err != nil {
			return RuntimePathResult{}, err
		}
	}
	raw, err := p.bytes()
	if err != nil {
		return RuntimePathResult{}, err
	}
	_, err = p.commit(ctx, raw, defaultSetupFileTransactionOps())
	return RuntimePathResult{p.changed, p.changed}, err
}
