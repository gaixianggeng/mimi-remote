package config

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// SetupPublication is the durable description of one setup transaction.
type SetupPublication struct {
	ConfigStage, TokenStage, Companion, Backup string
	Before, After, TokenDigest, IdentityDigest string
	Fresh                                      bool
}

type PublicationMember struct {
	Path, Digest string
}

func (r SetupPublication) Members(path string) ([]PublicationMember, error) {
	if len(r.After) != 64 || (r.Before != "" && len(r.Before) != 64) ||
		r.ConfigStage == "" || (r.TokenStage == "") != (r.Companion == "") ||
		(r.TokenStage != "" && len(r.TokenDigest) != 64) || (r.Before == "") != (r.Backup == "") {
		return nil, errors.New("恢复记录不完整")
	}
	var paths []PublicationMember
	for _, item := range []struct{ name, prefix, digest string }{
		{r.ConfigStage, ".config.json.tmp-", r.After}, {r.TokenStage, ".mimi-ws.tmp-", r.TokenDigest},
		{r.Companion, "app-server-ws-token-", r.TokenDigest}, {r.Backup, "." + filepath.Base(path) + ".bak-", r.Before},
	} {
		if item.name == "" {
			continue
		}
		if !filepath.IsLocal(item.name) || filepath.Base(item.name) != item.name || strings.ContainsAny(item.name, `/\:`) || !strings.HasPrefix(item.name, item.prefix) || len(item.name) == len(item.prefix) {
			return nil, errors.New("恢复路径无法验证")
		}
		paths = append(paths, PublicationMember{filepath.Join(filepath.Dir(path), item.name), item.digest})
	}
	if r.TokenStage != "" {
		paths = append(paths, PublicationMember{filepath.Join(filepath.Dir(path), r.TokenStage+".publish"), r.TokenDigest})
	}
	return paths, nil
}

func existingPermissionProblem(paths []string) (string, error) {
	for _, path := range paths {
		if err := CheckPrivatePermissions(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return path, err
		}
	}
	return "", nil
}

// CheckCompanionPermissions also covers an interrupted first install, when
// there is no config yet. Only a privately read journal supplies member names.
func CheckCompanionPermissions(path string) (string, error) {
	fixed := fixedCompanionPaths(path)
	if target, err := existingPermissionProblem(fixed); err != nil {
		return target, err
	}
	paths, err := publicationPaths(path)
	if err != nil {
		return SetupJournalPath(path), err
	}
	for _, member := range paths {
		if err := CheckPrivatePermissions(member.Path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return member.Path, err
		}
	}
	return "", nil
}

func fixedCompanionPaths(path string) []string {
	dir, journal := filepath.Dir(path), SetupJournalPath(path)
	paths := []string{journal, journal + ".identity", journal + ".recovery", path + ".diagnostics.token",
		filepath.Join(dir, "deepseek.token"), filepath.Join(dir, "tailcat", "local-control.token"),
		filepath.Join(dir, "tailcat", "managed-policy.json")}
	for _, name := range TailcatIdentityFiles() {
		paths = append(paths, filepath.Join(dir, "tailcat", name))
	}
	return paths
}

func publicationPaths(path string) ([]PublicationMember, error) {
	raw, err := ReadPrivatePreflightFile(SetupJournalPath(path), 8192)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var record SetupPublication
	if json.Unmarshal(raw, &record) != nil {
		return nil, nil // Recovery handles corrupt records without following their names.
	}
	paths, err := record.Members(path)
	if err != nil {
		return nil, nil
	}
	return paths, nil
}

// RepairInstallationPermissions only changes an inode whose hard links all
// belong to the selected installation. A journal must never redirect chmod to
// an unrelated file by naming a hard link with a plausible staging prefix.
func RepairInstallationPermissions(path, target string, explicit bool) (bool, error) {
	return repairPrivatePermissions(target, func(info os.FileInfo, links uint64) error {
		if filepath.Dir(target) == filepath.Join(filepath.Dir(path), "tailcat") {
			dir, err := os.Lstat(filepath.Dir(target))
			if err != nil || !dir.IsDir() {
				return errors.New("无法验证凭据目录")
			}
		}
		known := append(fixedCompanionPaths(path), path, target)
		members, err := publicationPaths(path)
		if err != nil && target != SetupJournalPath(path) {
			return err
		}
		for _, member := range members {
			known = append(known, member.Path)
			if member.Path == target {
				err := verifyRepairMember(member, info)
				// An owner can name an unreadable candidate explicitly. Readable
				// candidates must always match the original journal fingerprint.
				if err != nil && !(explicit && errors.Is(err, os.ErrPermission)) {
					return err
				}
			}
		}
		if links == 1 {
			return nil
		}
		names := make(map[string]bool)
		for _, candidate := range known {
			id, err := ConfigPathIdentity(candidate)
			if err != nil || names[id] {
				continue
			}
			if alias, err := permissionIdentity(candidate); err == nil && os.SameFile(info, alias) {
				names[id] = true
			}
		}
		if uint64(len(names)) != links {
			return errors.New("文件另有未经验证的硬链接")
		}
		return nil
	})
}

func verifyRepairMember(member PublicationMember, expected os.FileInfo) error {
	f, err := openSnapshotFile(member.Path)
	if err != nil {
		return err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || !os.SameFile(info, expected) {
		return errors.New("恢复文件已被替换")
	}
	h := sha256.New()
	n, err := io.Copy(h, io.LimitReader(f, (4<<20)+1))
	if err != nil {
		return err
	}
	if n > 4<<20 || hex.EncodeToString(h.Sum(nil)) != member.Digest {
		return errors.New("恢复文件内容已更改，请检查保留的文件")
	}
	return nil
}

// TailcatIdentityFiles are the state files preserved across relay reconfiguration.
func TailcatIdentityFiles() []string {
	return []string{
		"host.private.json",
		"host.address",
		"clients.json",
		"pair.private.json",
		"pair.address",
		"free.private.json",
		"free.address",
		"free-pair.private.json",
		"free-pair.address",
	}
}

// CheckTailcatIdentityPermissions checks the complete set before a sidecar
// operation moves, removes or recreates any member.
func CheckTailcatIdentityPermissions(dir string) error {
	for _, name := range TailcatIdentityFiles() {
		if err := CheckPrivatePermissions(filepath.Join(dir, name)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	return nil
}
