package config

import (
	"errors"
	"os"
)

// ReplacementPermissions records the source identity and access policy observed
// while staging. A rollback starts with the identity of the published generation.
type ReplacementPermissions struct {
	info     os.FileInfo
	original *fileDACL // Windows DACL before staging resolved inherited ACEs.
	token    bool
}

// PermissionConflict distinguishes an aborted rename from a published file
// that must be reread. Recovery means its final permissions need inspection.
type PermissionConflict struct {
	Published bool
	Recovery  bool
	Cause     error
}

func (e *PermissionConflict) Error() string { return e.Cause.Error() }
func (e *PermissionConflict) Unwrap() error { return e.Cause }

var errPermissionsChanged = errors.New("文件访问权限已更改，请重新读取")

// RollbackPermissions ties a backup rename to the file the transaction actually
// published. The replacement must also fit its latest access policy.
func RollbackPermissions(published os.FileInfo, token bool) ReplacementPermissions {
	return ReplacementPermissions{info: published, token: token}
}
