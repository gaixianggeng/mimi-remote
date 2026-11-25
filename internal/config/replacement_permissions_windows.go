package config

import (
	"errors"
	"os"

	"golang.org/x/sys/windows"
)

// Replace also guards rollback links, which have no creation-time snapshot.
// Keep WRITE_DAC on the staged object across the move so a newly installed
// deny cannot prevent correction or redirect it to a different pathname.
func (p ReplacementPermissions) Replace(stage, destination, backup string, move func(string, string) error) error {
	target, stagedInfo, err := openPermissionTarget(stage, true)
	if err != nil {
		return err
	}
	defer target.Close()
	sd, err := readStageDescriptor(target, p.token)
	if err != nil {
		return &PermissionConflict{Cause: err}
	}
	staged, err := filePolicy(sd)
	if err != nil {
		return err
	}

	displacedInfo := p.info
	sample := func(path string, witness bool) (daclSnapshot, error) {
		f, err := openPermissionHandle(path, windows.READ_CONTROL|windows.FILE_READ_ATTRIBUTES)
		if err != nil {
			return daclSnapshot{}, err
		}
		defer f.Close() // MoveFileEx requires the old destination to be closed.
		info, err := f.Stat()
		if err != nil {
			return daclSnapshot{}, err
		}
		if displacedInfo != nil && !os.SameFile(displacedInfo, info) {
			return daclSnapshot{}, errPermissionsChanged
		}
		displacedInfo = info
		if !info.Mode().IsRegular() {
			return daclSnapshot{}, errPermissionsChanged
		}
		var sd *windows.SECURITY_DESCRIPTOR
		if witness {
			// The displaced object is only an access ceiling. Even a NULL
			// or overly permissive DACL can be compared without reusing it.
			sd, err = fileSecurityDescriptor(f, fileSecurity)
		} else {
			sd, err = readStageDescriptor(f, p.token)
		}
		if err != nil {
			return daclSnapshot{}, err
		}
		policy, err := observedDACL(sd)
		return daclSnapshot{policy, func() error { return setReplacementDACL(target, sd, policy.protected) }}, err
	}
	ops := replaceDACLOps{
		destination: func() (daclSnapshot, error) { return sample(destination, false) },
		move:        func() error { return move(stage, destination) },
		retainStage: p.original != nil,
		replacement: func() (fileDACL, error) { return readPublishedDACL(target) },
		lockDown:    func() error { return lockDownDACL(target) },
	}
	if backup != "" {
		ops.displaced = func() (daclSnapshot, error) { return sample(backup, true) }
	}
	original := p.original
	if original == nil {
		// The source of a rollback is an old hard link. Check it against the
		// current destination, then resample the destination just before move.
		start, err := ops.destination()
		if err != nil {
			return &PermissionConflict{Cause: err}
		}
		original = &start.fileDACL
	}
	err = replaceWithDACL(*original, staged, ops)
	var conflict *PermissionConflict
	if err != nil && (!errors.As(err, &conflict) || !conflict.Published) {
		return err
	}
	// The readback and any correction used the pinned handle. Check identity
	// even after correction, without requiring data access to the new ACL.
	name, openErr := openPermissionHandle(destination, 0)
	if openErr == nil {
		defer name.Close()
		var info os.FileInfo
		info, openErr = name.Stat()
		if openErr == nil && os.SameFile(stagedInfo, info) {
			return err
		}
	}
	return &PermissionConflict{Published: true, Recovery: true, Cause: errors.Join(errPermissionsChanged, err, openErr)}
}

// CheckStageSource verifies a legacy source immediately before no-clobber
// publication at a new name. There is no displaced object to inspect afterwards.
func (p ReplacementPermissions) CheckStageSource(stage, source string) error {
	if err := CopyPrivatePermissions(source, stage); err != nil {
		return err
	}
	f, info, err := openPermissionTarget(source, false)
	if err != nil {
		return err
	}
	defer f.Close()
	sd, err := readStageDescriptor(f, p.token)
	if err != nil {
		return err
	}
	current, err := filePolicy(sd)
	if err != nil {
		return err
	}
	if !os.SameFile(info, p.info) || p.original == nil || !current.equal(*p.original) {
		return &PermissionConflict{Cause: errPermissionsChanged}
	}
	return nil
}

func readPublishedDACL(file *os.File) (fileDACL, error) {
	sd, err := fileSecurityDescriptor(file, fileSecurity)
	if err != nil {
		return fileDACL{}, err
	}
	return observedDACL(sd)
}

func observedDACL(sd *windows.SECURITY_DESCRIPTOR) (fileDACL, error) {
	acl, _, err := sd.DACL()
	if errors.Is(err, windows.ERROR_OBJECT_NOT_FOUND) || (err == nil && acl == nil) {
		return fileDACL{unrestricted: true}, nil
	}
	if err != nil {
		return fileDACL{}, err
	}
	return filePolicy(sd)
}

func setReplacementDACL(file *os.File, sd *windows.SECURITY_DESCRIPTOR, protected bool) error {
	acl, _, err := sd.DACL()
	if err != nil || acl == nil {
		return windows.ERROR_INVALID_ACL
	}
	flags := windows.SECURITY_INFORMATION(windows.UNPROTECTED_DACL_SECURITY_INFORMATION)
	if protected {
		flags = windows.PROTECTED_DACL_SECURITY_INFORMATION
	}
	return windows.SetSecurityInfo(windows.Handle(file.Fd()), windows.SE_FILE_OBJECT,
		windows.DACL_SECURITY_INFORMATION|flags, nil, nil, acl, nil)
}

func lockDownDACL(file *os.File) error {
	// No allows. The OWNER RIGHTS deny also suppresses implicit owner
	// READ_CONTROL/WRITE_DAC. Recovery may require administrative access.
	sd, err := windows.SecurityDescriptorFromString("D:P(D;;FA;;;OW)")
	if err != nil {
		return err
	}
	if err := setReplacementDACL(file, sd, true); err != nil {
		return err
	}
	got, err := readPublishedDACL(file)
	if err != nil {
		return err
	}
	acl, _, err := sd.DACL()
	if err != nil {
		return err
	}
	var deny *windows.ACCESS_ALLOWED_ACE
	if err := windows.GetAce(acl, 0, &deny); err != nil {
		return err
	}
	if !got.protected || len(got.entries) != 1 || got.entries[0].encoded != encodedACE(deny) {
		return errPermissionsChanged
	}
	return nil
}
