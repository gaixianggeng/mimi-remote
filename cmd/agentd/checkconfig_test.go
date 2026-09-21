package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestConfigCheckFailureCodeSeparatesUpgradeFromOtherConfigErrors(t *testing.T) {
	upgrade := fmt.Errorf(
		"旧 app_server.transport=%q 不能自动迁移：%w",
		"local",
		config.ErrAppServerTransportUnsupported,
	)
	if got := configCheckFailureCode(upgrade); got != configCheckCodeRequiresNewerVersion {
		t.Fatalf("配置需要更新版本时必须给出升级码，得到 %q", got)
	}
	if got := configCheckFailureCode(errors.New("auth.token 不能为空")); got != configCheckCodeInvalid {
		t.Fatalf("其它配置问题不得被当成升级场景，得到 %q", got)
	}
}

func TestReportConfigCheckKeepsJSONParseableWhenTheCheckFails(t *testing.T) {
	var buf bytes.Buffer
	checkErr := fmt.Errorf("旧 app_server.transport=%q 不能自动迁移：%w", "local", config.ErrAppServerTransportUnsupported)
	if err := reportConfigCheck(&buf, true, checkErr); !errors.Is(err, config.ErrAppServerTransportUnsupported) {
		t.Fatalf("检查失败必须保持非零退出语义：%v", err)
	}

	var result configCheckResult
	if err := json.Unmarshal(buf.Bytes(), &result); err != nil {
		t.Fatalf("stdout 必须始终是可解析 JSON：%v（原文 %q）", err, buf.String())
	}
	if result.OK {
		t.Fatal("失败的检查不得报告 ok")
	}
	if result.Code != configCheckCodeRequiresNewerVersion {
		t.Fatalf("失败码必须是升级指引：%q", result.Code)
	}
	if !strings.Contains(result.Message, "请升级到最新发布包") {
		t.Fatalf("失败信息必须告诉用户升级安装包：%q", result.Message)
	}
}

func TestReportConfigCheckReportsSuccessWithoutMessage(t *testing.T) {
	var buf bytes.Buffer
	if err := reportConfigCheck(&buf, true, nil); err != nil {
		t.Fatalf("配置可用时不应返回错误：%v", err)
	}
	var result configCheckResult
	if err := json.Unmarshal(buf.Bytes(), &result); err != nil {
		t.Fatalf("stdout 必须始终是可解析 JSON：%v", err)
	}
	if !result.OK || result.Code != configCheckCodeOK || result.Message != "" {
		t.Fatalf("通过的检查必须只报告 ok：%+v", result)
	}
}

// check-config 存在的意义是复现 serve 的启动失败原因，因此这里直接跑真实流水线，
// 断言 App 会拿到「升级安装包」而不是一句无法执行的迁移提示。
func TestCheckConfigReusesServePipelineForUnsupportedTransport(t *testing.T) {
	dir := t.TempDir()
	configPath := filepath.Join(dir, "config.json")
	projectPath := filepath.Join(dir, "project")
	if err := os.Mkdir(projectPath, 0o755); err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(map[string]any{
		"listen":  "127.0.0.1:8787",
		"auth":    map[string]any{"token": "0123456789abcdef0123456789abcdef"},
		"runtime": map[string]any{"type": "codex_app_server"},
		// 模拟更新版本写入、当前包无法识别的传输方式。
		"app_server": map[string]any{"transport": "shared-local-v2"},
		"projects": []map[string]any{{
			"id": "demo", "name": "Demo", "path": projectPath,
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(configPath, raw, 0o600); err != nil {
		t.Fatal(err)
	}

	// run() 会先剥掉子命令名，这里保持一致，避免 flag 包把子命令当成位置参数后停止解析。
	asJSON, checkErr := checkConfig([]string{"agentd", "--config", configPath, "--json"})
	if !asJSON {
		t.Fatal("--json 必须传到结果渲染层")
	}
	if !errors.Is(checkErr, config.ErrAppServerTransportUnsupported) {
		t.Fatalf("check-config 必须复现 serve 的传输方式错误：%v", checkErr)
	}
	if got := configCheckFailureCode(checkErr); got != configCheckCodeRequiresNewerVersion {
		t.Fatalf("App 依赖的失败码必须表示需要升级安装包：%q", got)
	}
}
