package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

// configCheckResult 是 `agentd check-config` 的机器可判读输出。macOS App 在后台
// 服务反复启动失败时调用它，用 code 决定是引导用户升级安装包，还是继续走原本的
// 登记修复；code 是稳定契约，不要为了改文案而改名。
type configCheckResult struct {
	OK      bool   `json:"ok"`
	Code    string `json:"code"`
	Message string `json:"message,omitempty"`
}

const (
	configCheckCodeOK                   = "ok"
	configCheckCodeRequiresNewerVersion = "config_requires_newer_version"
	configCheckCodeInvalid              = "config_invalid"
)

func runCheckConfig(args []string) error {
	asJSON, checkErr := checkConfig(args)
	return reportConfigCheck(os.Stdout, asJSON, checkErr)
}

// checkConfig 复用 serve 启动前的同一段配置流水线（旧配置迁移、Codex 路径修复、
// 共享 App Server 迁移与配置校验），但只做检查：不监听端口，也不启动任何运行时。
// App 因此能拿到与 launchd 实际遇到的完全同一个失败原因。
func checkConfig(args []string) (bool, error) {
	asJSON := false
	_, _, _, checkErr := loadRuntimeConfig(args, false, func(fs *flag.FlagSet) {
		fs.BoolVar(&asJSON, "json", false, "以 JSON 输出检查结果")
	})
	return asJSON, checkErr
}

func reportConfigCheck(w io.Writer, asJSON bool, checkErr error) error {
	result := configCheckResult{OK: checkErr == nil, Code: configCheckCodeOK}
	if checkErr != nil {
		result.Code = configCheckFailureCode(checkErr)
		result.Message = checkErr.Error()
	}
	switch {
	case asJSON:
		if err := printJSONTo(w, result); err != nil {
			return err
		}
	case checkErr == nil:
		fmt.Fprintln(w, "配置检查通过：当前 agentd 可以按这份配置启动。")
	default:
		fmt.Fprintf(w, "配置检查未通过（%s）：%v\n", result.Code, checkErr)
	}
	// JSON 已经写进 stdout，这里再返回错误只影响退出码与 stderr，stdout 保持可解析。
	return checkErr
}

// configCheckFailureCode 只区分「这份配置需要更新版本的 agentd」与「其它配置问题」。
// 前者在 App 中对应升级安装包的引导，后者保持原有的登记修复路径。
func configCheckFailureCode(err error) string {
	if errors.Is(err, config.ErrAppServerTransportUnsupported) {
		return configCheckCodeRequiresNewerVersion
	}
	return configCheckCodeInvalid
}
