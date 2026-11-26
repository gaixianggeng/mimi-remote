//go:build !windows && !linux && !darwin

package privatefile

import (
	"errors"
	"os"
)

var errACLUnsupported = errors.New("此平台无法验证文件 ACL")

func checkPermissionVolume(*os.File) error      { return errACLUnsupported }
func checkExtendedACL(*os.File) error           { return errACLUnsupported }
func createPrivateNew(string) (*os.File, error) { return nil, errACLUnsupported }
func prepareStage(*os.File) error               { return errACLUnsupported }
