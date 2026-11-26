package setup

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

// This private record identifies the exact files owned by one publication.
// In particular, a filename prefix alone is never evidence of ownership.
type publication struct {
	ConfigStage, TokenStage, Companion, Backup string
	Before, After, TokenDigest, IdentityDigest string
	Fresh                                      bool
}

func digest(raw []byte) string { v := sha256.Sum256(raw); return hex.EncodeToString(v[:]) }
func recoveryError(path string, err error) error {
	return &SaveError{Code: "config_recovery_required", Step: "config_store", ConfigPath: "<配置目录>/config.json", RecoveryPath: "<配置目录>/" + filepath.Base(path), Cause: err}
}
func recoverPublication(ctx context.Context, path, legacy string, ops setupFileTransactionOps, identity *interruptedIdentity) error {
	j := config.SetupJournalPath(path)
	if _, err := os.Lstat(j + ".recovery"); !errors.Is(err, os.ErrNotExist) {
		return recoveryError(j, errors.New("上一次提交需要手动检查"))
	}
	if !filePresent(j) && !filePresent(j+".identity") {
		return nil
	}
	return config.WithConfigCommitLock(ctx, path, func() error {
		_, err := readPrivateConfig(path)
		if errors.Is(err, os.ErrNotExist) && legacy != "" {
			_, err = readPrivateConfig(legacy)
		}
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		stored, err := readInterruptedIdentity(j + ".identity")
		if err != nil {
			return err
		}
		if err = inspectPublication(path, ops, &stored); err != nil {
			// A failed replay must remain visible to passive preflight as well.
			if e := publishSetupCompanion(j, j+".recovery", ops); e == nil {
				_ = ops.syncDir(filepath.Dir(path))
			}
			return err
		}
		if identity != nil {
			*identity = stored
		}
		return nil
	})
}

func replayPublication(path string, ops setupFileTransactionOps) error {
	return inspectPublication(path, ops, nil)
}

func inspectPublication(path string, ops setupFileTransactionOps, identity *interruptedIdentity) error {
	journal := config.SetupJournalPath(path)
	if _, err := os.Lstat(journal + ".recovery"); !errors.Is(err, os.ErrNotExist) {
		return recoveryError(journal, errors.New("上一次提交需要手动检查"))
	}
	data, err := config.ReadPrivatePreflightFile(journal, 8192)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return recoveryError(journal, err)
	}
	var record publication
	if err = json.Unmarshal(data, &record); err != nil {
		return recoveryError(journal, err)
	}
	dir := filepath.Dir(path)
	// Check the full record, its bounded names and fingerprints before unlinking anything.
	if len(record.After) != 64 || (record.Before != "" && len(record.Before) != 64) {
		return recoveryError(journal, errors.New("恢复记录不完整"))
	}
	if record.ConfigStage == "" || (record.TokenStage == "") != (record.Companion == "") ||
		(record.TokenStage != "" && len(record.TokenDigest) != 64) || (record.Before == "") != (record.Backup == "") {
		return recoveryError(journal, errors.New("恢复记录不完整"))
	}
	for _, entry := range []struct{ name, prefix string }{
		{record.ConfigStage, ".config.json.tmp-"}, {record.TokenStage, ".mimi-ws.tmp-"},
		{record.Companion, "app-server-ws-token-"}, {record.Backup, "." + filepath.Base(path) + ".bak-"},
	} {
		if entry.name != "" && (filepath.Base(entry.name) != entry.name || !strings.HasPrefix(entry.name, entry.prefix)) {
			return recoveryError(journal, errors.New("恢复路径无法验证"))
		}
	}
	image, err := readImage(path)
	if err != nil {
		return recoveryError(journal, err)
	}
	current := ""
	if image.exists {
		current = digest(image.raw)
	}
	if current != record.Before && current != record.After {
		return recoveryError(journal, errors.New("配置已在事务外修改，请检查保留的文件"))
	}
	removeOwned := func(name, hash string) error {
		if name == "" {
			return nil
		}
		file := filepath.Join(dir, name)
		raw, e := config.ReadPrivatePreflightFile(file, 4<<20)
		if errors.Is(e, os.ErrNotExist) {
			return nil
		}
		if e != nil || digest(raw) != hash {
			return errors.New("无法验证暂存文件")
		}
		return ops.remove(file)
	}
	// Replay can itself be interrupted after unlinking a stage. The durable
	// identity witness is sufficient only when both secrets match this record.
	if record.Fresh && current == "" && identity != nil && (identity.Bearer == "" || identity.digest() != record.IdentityDigest) {
		staged, e := config.ReadPrivatePreflightFile(filepath.Join(dir, record.ConfigStage), 4<<20)
		if e != nil || digest(staged) != record.After {
			return recoveryError(journal, errors.New("无法验证中断的初始配置"))
		}
		parsed := config.ParseSetupDocument(staged)
		if parsed.Code != "" {
			return recoveryError(journal, errors.New("初始配置需要恢复"))
		}
		identity.Bearer = parsed.Config.Auth.Token
		if record.TokenStage != "" {
			ws, e := config.ReadPrivatePreflightFile(filepath.Join(dir, record.TokenStage), 4096)
			if e != nil || digest(ws) != record.TokenDigest {
				return recoveryError(journal, errors.New("无法验证中断的初始凭据"))
			}
			identity.Upstream = strings.TrimSpace(string(ws))
		}
		if e := keepInterruptedIdentity(journal, *identity, ops); e != nil {
			return recoveryError(journal, e)
		}
	}
	if current == record.After && record.Companion != "" {
		tok, e := config.ReadPrivatePreflightFile(filepath.Join(dir, record.Companion), 4096)
		if e != nil || digest(tok) != record.TokenDigest {
			return recoveryError(journal, errors.New("配置引用的凭据需要恢复"))
		}
	}
	if err = ops.syncDir(dir); err != nil {
		return recoveryError(journal, err)
	}
	if current != record.After && record.Companion != "" {
		// Only remove the unique companion if it is still the staged inode.
		name := filepath.Join(dir, record.Companion)
		a, e := os.Lstat(name)
		if e == nil {
			b, e := os.Lstat(filepath.Join(dir, record.TokenStage))
			if e != nil || !os.SameFile(a, b) {
				return recoveryError(journal, errors.New("无法验证伴随文件的归属"))
			}
			if err = removeOwned(record.Companion, record.TokenDigest); err != nil {
				return recoveryError(journal, err)
			}
		} else if !errors.Is(e, os.ErrNotExist) {
			return recoveryError(journal, e)
		}
	}
	if record.TokenStage != "" {
		if err = removeCompanionAlias(filepath.Join(dir, record.TokenStage), ops); err != nil {
			return recoveryError(journal, err)
		}
	}
	for _, item := range []struct{ name, sum string }{{record.Backup, record.Before}, {record.ConfigStage, record.After}, {record.TokenStage, record.TokenDigest}} {
		if err = removeOwned(item.name, item.sum); err != nil {
			return recoveryError(journal, err)
		}
	}
	if err = ops.remove(journal); err != nil {
		return recoveryError(journal, err)
	}
	return nil
}
func (p *proposal) commit(ctx context.Context, raw []byte, ops setupFileTransactionOps) (result config.Config, returned error) {
	path := p.dest.path
	dir := filepath.Dir(path)
	created, err := ensureSetupDirectory(dir, ops.syncDir)
	if err != nil {
		return result, saveFailure("config_dir_unwritable", err)
	}
	if created != nil {
		defer func() {
			if returned != nil {
				removeCreatedDirectory(dir, created)
			}
		}()
	}
	changes := !p.dest.exists || !bytes.Equal(raw, p.dest.raw)
	stage, tokenStage := "", ""
	var stageInfo, tokenInfo os.FileInfo
	journal := config.SetupJournalPath(path)
	keep := false
	lockedCleanup := false
	cleanupStages := func() error {
		if !keep {
			p.removeSetupFileIfOwned(stage, stageInfo, raw, ops)
			p.removeSetupFileIfOwned(tokenStage, tokenInfo, p.token, ops)
		}
		return nil
	}
	defer func() {
		if !lockedCleanup && (stageInfo != nil || tokenInfo != nil) {
			// Staging failed or the original lock attempt timed out. Prefer
			// leaving private debris to deleting anything during another commit.
			cleanupCtx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			_ = config.WithConfigCommitLock(cleanupCtx, path, cleanupStages)
		}
	}()
	if changes {
		stage, err = ops.stage(dir, ".config.json.tmp-", raw)
		if err == nil {
			stageInfo, err = config.FileIdentity(stage)
		}
		if err == nil && p.companion != "" {
			tokenStage, err = ops.stage(dir, ".mimi-ws.tmp-", p.token)
			if err == nil {
				tokenInfo, err = config.FileIdentity(tokenStage)
			}
		}
		if err != nil {
			if p.source.exists {
				if conflict := p.source.check(); conflict != nil {
					return result, conflict
				}
			}
			return result, saveFailure("config_commit_failed", err)
		}
	}
	err = config.WithConfigCommitLock(ctx, path, func() (commitErr error) {
		lockedCleanup = true
		defer cleanupStages()
		defer func() {
			var failed *SaveError
			if keep && errors.As(commitErr, &failed) && failed.Code == "config_recovery_required" {
				// A crash can be replayed. A known indeterminate rollback needs
				// read-only recovery; never discard its old or new generation.
				if e := publishSetupCompanion(journal, journal+".recovery", ops); e == nil {
					_ = ops.syncDir(dir)
				}
			}
		}()
		// Only recovery before building a proposal can adopt an interrupted
		// identity. A journal that appeared since then belongs to another writer.
		if filePresent(journal + ".recovery") {
			return recoveryError(journal, errors.New("上一次提交需要手动检查"))
		}
		if filePresent(journal) {
			return saveFailure("config_concurrent_change", errors.New("配置事务已更改，请重新选择"))
		}
		id, err := readInterruptedIdentity(journal + ".identity")
		if err != nil {
			return err
		}
		if id.Bearer != "" {
			upstream := p.referencedToken.raw
			if p.companion != "" {
				upstream = p.token
			}
			if id.Bearer != p.cfg.Auth.Token || (id.Upstream != "" && p.cfg.AppServer.Transport == "ws" && id.Upstream != strings.TrimSpace(string(upstream))) {
				if p.source.exists {
					return recoveryError(journal+".identity", errors.New("保留的身份与原配置不同"))
				}
				return saveFailure("config_concurrent_change", errors.New("保留的身份已更改，请重新检查配置"))
			}
		}
		if err := p.check(ctx); err != nil {
			return err
		}
		if changes {
			if !sameSetupFile(stage, stageInfo, raw) || (tokenStage != "" && !sameSetupFile(tokenStage, tokenInfo, p.token)) {
				return saveFailure("config_concurrent_change", errors.New("暂存文件已被替换"))
			}
			r := publication{ConfigStage: filepath.Base(stage), After: digest(raw), Fresh: !p.source.exists}
			if r.Fresh {
				r.IdentityDigest = (interruptedIdentity{Bearer: p.cfg.Auth.Token, Upstream: strings.TrimSpace(string(p.token))}).digest()
			}
			if p.dest.exists {
				r.Before = digest(p.dest.raw)
			}
			if tokenStage != "" {
				r.TokenStage = filepath.Base(tokenStage)
				r.Companion = filepath.Base(p.companion)
				r.TokenDigest = digest(p.token)
			}
			backup, err := hardLinkBackup(path, p.dest.exists, ops)
			if err != nil {
				return err
			}
			var backupInfo os.FileInfo
			if backup != "" {
				r.Backup = filepath.Base(backup)
				backupInfo, err = config.FileIdentity(backup)
				if err != nil {
					return err
				}
			}
			defer func() {
				if !keep && backup != "" {
					// The old config may have been edited in place. Unlinking
					// its own backup link leaves that editor's config intact.
					if now, e := os.Lstat(backup); e == nil && os.SameFile(backupInfo, now) {
						if used, e := p.referencesPath(backup); e == nil && !used {
							_ = ops.remove(backup)
						}
					}
				}
			}()
			manifest, _ := json.Marshal(r)
			stagedJournal, err := ops.stage(dir, ".mimi-publish.tmp-", manifest)
			if err != nil {
				return err
			}
			// Publish the flushed journal with the same no-clobber, write-through
			// rename as a fresh config, including on Windows without directory fsync.
			if err = ops.renameNew(stagedJournal, journal); err != nil {
				if errors.Is(err, os.ErrExist) {
					_ = ops.remove(stagedJournal)
					return saveFailure("config_concurrent_change", err)
				}
				if filePresent(journal) {
					keep = true
					return recoveryError(journal, err)
				}
				_ = ops.remove(stagedJournal)
				return err
			}
			keep = true
			// Journal and rollback inode must be durable before exposing either file.
			cleanup := func(cause error) error {
				if err := replayPublication(path, ops); err != nil {
					return err
				}
				stage, tokenStage, backup = "", "", ""
				keep = false
				return cause
			}
			if err = ops.syncDir(dir); err != nil {
				return cleanup(err)
			}
			if tokenStage != "" {
				if err = publishSetupCompanion(tokenStage, p.companion, ops); err != nil {
					return cleanup(err)
				}
				if err = ops.syncDir(dir); err != nil {
					return cleanup(err)
				}
			}
			abandon := func(cause error) error {
				if tokenStage != "" {
					if e := dropUnreferencedCompanion(p, tokenStage, ops); e != nil {
						return recoveryError(journal, e)
					}
				}
				if e := ops.remove(journal); e != nil {
					return recoveryError(journal, e)
				}
				keep = false
				return cause
			}
			if !sameSetupFile(stage, stageInfo, raw) || (tokenStage != "" && !sameSetupFile(p.companion, tokenInfo, p.token)) {
				return recoveryError(journal, errors.New("暂存文件已更改"))
			}
			if err = p.check(ctx); err != nil {
				return abandon(err)
			}
			publish := ops.rename
			if !p.dest.exists {
				publish = ops.renameNew
			}
			if err = publish(stage, path); err != nil {
				if !p.dest.exists && errors.Is(err, os.ErrExist) {
					return abandon(saveFailure("config_concurrent_change", err))
				}
				if changed := p.dest.check(); changed != nil {
					return recoveryError(journal, err)
				}
				return cleanup(err)
			}
			if err = ops.syncDir(dir); err != nil {
				// Roll back only our generation, retaining the backup link through sync.
				current, e := config.ReadPrivatePreflightFile(path, 4<<20)
				if e != nil || !bytes.Equal(current, raw) {
					return recoveryError(journal, errors.Join(err, e))
				}
				publishedInfo, e := os.Lstat(path)
				if e != nil || !os.SameFile(stageInfo, publishedInfo) {
					return recoveryError(journal, errors.Join(err, e))
				}
				if backup != "" {
					rollback := stage
					if !sameSetupFile(backup, backupInfo, p.dest.raw) {
						return recoveryError(journal, errors.New("恢复点的内容或权限已更改"))
					}
					if e = ops.link(backup, rollback); e == nil {
						e = ops.rename(rollback, path)
					}
				} else {
					e = ops.remove(path)
				}
				if e != nil {
					return recoveryError(journal, errors.Join(err, e))
				}
				if e = ops.syncDir(dir); e != nil {
					return recoveryError(journal, errors.Join(err, e))
				}
				return cleanup(err)
			}
		}
		committed, e := config.ReadPrivatePreflightFile(path, 4<<20)
		if e != nil || !bytes.Equal(committed, raw) {
			return recoveryError(journal, errors.New("无法确认已提交的配置"))
		}
		s := config.InspectCommittedDocument(committed)
		if s.Code != "" {
			return recoveryError(journal, errors.New("无法验证已提交的配置"))
		}
		result = s.Config
		if keep {
			if err := replayPublication(path, ops); err != nil {
				return err
			}
			stage, tokenStage = "", ""
			keep = false
		}
		return forgetCommittedIdentity(journal, result, ops)
	})
	if err != nil {
		return result, saveFailure("config_commit_failed", err)
	}
	return result, nil
}

func sameSetupFile(path string, expected os.FileInfo, raw []byte) bool {
	if expected == nil || !expected.Mode().IsRegular() {
		return false
	}
	now, err := os.Lstat(path)
	if err != nil || !os.SameFile(expected, now) {
		return false
	}
	current, err := config.ReadPrivatePreflightFile(path, 4<<20)
	return err == nil && bytes.Equal(current, raw)
}

func (p *proposal) removeSetupFileIfOwned(path string, expected os.FileInfo, raw []byte, ops setupFileTransactionOps) {
	if sameSetupFile(path, expected, raw) {
		if used, err := p.referencesPath(path); err == nil && !used {
			_ = ops.remove(path)
		}
	}
}

// A non-cooperating editor can adopt the newly published companion before
// config CAS. Never unlink it from underneath the editor's committed document.
func dropUnreferencedCompanion(p *proposal, stage string, ops setupFileTransactionOps) error {
	used, err := p.referencesPath(p.companion)
	if err != nil || used {
		return err
	}
	return removeLinkedCompanion(stage, p.companion, ops)
}

func (p *proposal) referencesPath(path string) (bool, error) {
	for _, src := range []configImage{p.dest, p.legacy} {
		if src.path == "" {
			continue
		}
		image, err := readImage(src.path)
		if err != nil {
			return false, err
		}
		if !image.exists {
			continue
		}
		var values any
		if err = json.Unmarshal(image.raw, &values); err != nil {
			return false, err
		}
		if referencesFile(values, path) {
			return true, nil
		}
	}
	return false, nil
}
func referencesFile(value any, path string) bool {
	switch v := value.(type) {
	case string:
		if !filepath.IsAbs(config.ExpandPath(v)) {
			return false
		}
		left, e := config.ConfigPathIdentity(v)
		right, _ := config.ConfigPathIdentity(path)
		return e == nil && left == right
	case []any:
		for _, child := range v {
			if referencesFile(child, path) {
				return true
			}
		}
	case map[string]any:
		for _, child := range v {
			if referencesFile(child, path) {
				return true
			}
		}
	}
	return false
}

func removeLinkedCompanion(stage, path string, ops setupFileTransactionOps) error {
	a, err := os.Lstat(stage)
	if err != nil {
		return err
	}
	b, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !os.SameFile(a, b) {
		return fmt.Errorf("伴随文件已替换")
	}
	return ops.remove(path)
}

func removeCompanionAlias(stage string, ops setupFileTransactionOps) error {
	alias := stage + ".publish"
	if _, err := os.Lstat(alias); errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return removeLinkedCompanion(stage, alias, ops)
}
