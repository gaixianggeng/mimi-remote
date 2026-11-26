package main

import (
	"errors"
	"flag"
	"path/filepath"
)

func validateBootstrapFlags(fs *flag.FlagSet, platform string, bootstrap, noPair, asJSON bool, root string) error {
	if !bootstrap && !flagSetByCaller(fs, "lan-enabled") && !flagSetByCaller(fs, "require-existing") {
		return nil
	}
	if !bootstrap || platform != "windows" || !noPair || !asJSON || !flagSetByCaller(fs, "lan-enabled") {
		return invalidOnboardingRequest(errors.New("安装器必须显式选择局域网策略并使用安全启动模式"))
	}
	allowed := map[string]bool{"installer-bootstrap": true, "lan-enabled": true, "no-pair": true, "json": true, "wait": true, "scan-root": true, "require-existing": true}
	valid := true
	fs.Visit(func(f *flag.Flag) { valid = valid && allowed[f.Name] })
	if !valid || (flagSetByCaller(fs, "scan-root") && !filepath.IsAbs(root)) {
		return invalidOnboardingRequest(errors.New("安装器只能确认一个明确选择的绝对目录"))
	}
	return nil
}
