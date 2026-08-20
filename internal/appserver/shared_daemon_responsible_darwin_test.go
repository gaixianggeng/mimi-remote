//go:build darwin

package appserver

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const codexDaemonSupervisorSwiftPath = "../../macos/MimiRemoteMac/Sources/App/CodexDaemonSupervisor.swift"

func writeTestAppBundle(t *testing.T) (bundle string, mainExecutable string, resource string) {
	t.Helper()
	root := t.TempDir()
	bundle = filepath.Join(root, "Mimi Remote Mac.app")
	macOS := filepath.Join(bundle, "Contents", "MacOS")
	resources := filepath.Join(bundle, "Contents", "Resources")
	for _, directory := range []string{macOS, resources} {
		if err := os.MkdirAll(directory, 0o755); err != nil {
			t.Fatalf("创建测试 bundle 失败：%v", err)
		}
	}
	infoPlist := filepath.Join(bundle, "Contents", "Info.plist")
	infoContent := []byte(`<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Mimi Remote Mac</string>
</dict></plist>`)
	if err := os.WriteFile(infoPlist, infoContent, 0o644); err != nil {
		t.Fatalf("写入 Info.plist 失败：%v", err)
	}
	mainExecutable = filepath.Join(macOS, "Mimi Remote Mac")
	if err := os.WriteFile(mainExecutable, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatalf("写入主可执行文件失败：%v", err)
	}
	resource = filepath.Join(resources, "agentd")
	if err := os.WriteFile(resource, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatalf("写入 agentd 失败：%v", err)
	}
	return bundle, mainExecutable, resource
}

func TestSharedDaemonAppBundleOnlyAcceptsResourcesLayout(t *testing.T) {
	bundle, _, resource := writeTestAppBundle(t)
	got, ok := sharedDaemonAppBundleForResource(resource)
	if !ok || got != bundle {
		t.Fatalf("期望识别出 %q，实际 %q ok=%v", bundle, got, ok)
	}
	// 仓库里、临时目录里的同名二进制不能被当成安装态 App，否则会把开发构建
	// 误挂成 TCC 责任进程。
	for _, path := range []string{
		filepath.Join(bundle, "Contents", "MacOS", "agentd"),
		filepath.Join(t.TempDir(), "agentd"),
		filepath.Join(t.TempDir(), "Contents", "Resources", "agentd"),
	} {
		if _, ok := sharedDaemonAppBundleForResource(path); ok {
			t.Fatalf("不应把 %q 识别为 App bundle 内的 agentd", path)
		}
	}
}

func TestSharedDaemonBundleMainExecutableUsesInfoPlistWithDebugLibraries(t *testing.T) {
	bundle, mainExecutable, _ := writeTestAppBundle(t)
	for _, name := range []string{"Mimi Remote Mac.debug.dylib", "__preview.dylib"} {
		if err := os.WriteFile(filepath.Join(bundle, "Contents", "MacOS", name), []byte("debug"), 0o755); err != nil {
			t.Fatalf("写入 Debug dylib 失败：%v", err)
		}
	}
	got, err := sharedDaemonBundleMainExecutable(bundle)
	if err != nil {
		t.Fatalf("解析主可执行文件失败：%v", err)
	}
	if resolved, resolveErr := filepath.EvalSymlinks(mainExecutable); resolveErr != nil || got != resolved {
		t.Fatalf("期望 %q，实际 %q（err=%v）", mainExecutable, got, resolveErr)
	}
}

func TestSharedDaemonBundleMainExecutableRejectsInvalidInfoPlistTarget(t *testing.T) {
	bundle, _, _ := writeTestAppBundle(t)
	infoPlist := filepath.Join(bundle, "Contents", "Info.plist")
	for _, executableName := range []string{"", "../Resources/agentd", "Missing"} {
		content := []byte("<plist><dict><key>CFBundleExecutable</key><string>" + executableName + "</string></dict></plist>")
		if err := os.WriteFile(infoPlist, content, 0o644); err != nil {
			t.Fatalf("改写 Info.plist 失败：%v", err)
		}
		if _, err := sharedDaemonBundleMainExecutable(bundle); err == nil {
			t.Fatalf("CFBundleExecutable=%q 时必须报错", executableName)
		}
	}
}

func TestSharedDaemonLaunchAgentProgramArgumentsKeepsNodeChainWithoutApp(t *testing.T) {
	node := "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node"
	codex := "/Applications/ChatGPT.app/Contents/Resources/codex"
	// Homebrew / 开发构建下没有 App bundle，必须保持既有 ProgramArguments，
	// 不能因为新增责任进程而让现存安装的 plist 无谓改写重启。
	got := sharedDaemonLaunchAgentProgramArguments("", node, codex)
	want := sharedDaemonSupervisorProgramArguments(node, codex)
	if strings.Join(got, "\x00") != strings.Join(want, "\x00") {
		t.Fatalf("期望沿用 node 链条 %v，实际 %v", want, got)
	}
}

func TestSharedDaemonLaunchAgentProgramArgumentsNeverForwardsSupervisorScript(t *testing.T) {
	responsible := "/Applications/Mimi Remote Mac.app/Contents/MacOS/Mimi Remote Mac"
	node := "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node"
	codex := "/Applications/ChatGPT.app/Contents/Resources/codex"
	got := sharedDaemonLaunchAgentProgramArguments(responsible, node, codex)

	want := []string{responsible, sharedDaemonResponsibleSupervisorFlag, node, codex}
	if strings.Join(got, "\x00") != strings.Join(want, "\x00") {
		t.Fatalf("期望 %v，实际 %v", want, got)
	}
	// 脚本正文一旦能从命令行注入，任何同用户进程都可以借 Mimi 的 TCC 授权执行
	// 任意 JS。这条断言守的就是这个边界，不是参数顺序。
	for _, argument := range got {
		if strings.Contains(argument, "require(") || strings.Contains(argument, "use strict") {
			t.Fatalf("ProgramArguments 不能携带 supervisor 脚本正文：%q", argument)
		}
	}
}

func TestRenderSharedDaemonLaunchAgentPutsResponsibleProcessFirst(t *testing.T) {
	responsible := "/Applications/Mimi Remote Mac.app/Contents/MacOS/Mimi Remote Mac"
	original := sharedDaemonResolveResponsibleSupervisor
	sharedDaemonResolveResponsibleSupervisor = func() (string, error) { return responsible, nil }
	t.Cleanup(func() { sharedDaemonResolveResponsibleSupervisor = original })

	node := "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node"
	codex := "/Applications/ChatGPT.app/Contents/Resources/codex"
	rendered, err := renderSharedDaemonLaunchAgent(node, codex, nil, "/tmp/shared.log")
	if err != nil {
		t.Fatalf("渲染 plist 失败：%v", err)
	}
	content := string(rendered)

	// launchd 用 ProgramArguments[0] 作为程序路径：责任进程必须排在最前，
	// 否则 TCC 主体仍然是裸二进制 node。
	first := strings.Index(content, "<string>"+responsible+"</string>")
	nodeIndex := strings.Index(content, "<string>"+node+"</string>")
	if first < 0 || nodeIndex < 0 || first > nodeIndex {
		t.Fatalf("责任进程必须是第一个 ProgramArgument：\n%s", content)
	}
	if !strings.Contains(content, "<string>"+sharedDaemonResponsibleSupervisorFlag+"</string>") {
		t.Fatalf("plist 缺少 supervisor 旗标：\n%s", content)
	}
	if strings.Contains(content, "<string>/bin/sh</string>") || strings.Contains(content, "use strict") {
		t.Fatalf("plist 不能引入 shell 或 supervisor 脚本正文：\n%s", content)
	}
	if value := sharedDaemonPlistStringValue(rendered, sharedDaemonPinnedCodexEnvironmentKey); value != "" {
		t.Fatalf("Mimi supervisor 必须自行注入 staged codex，plist 不得传入原始路径：%q", value)
	}
}

func TestRenderSharedDaemonLaunchAgentRejectsBrokenAppResponsibleProcess(t *testing.T) {
	original := sharedDaemonResolveResponsibleSupervisor
	sharedDaemonResolveResponsibleSupervisor = func() (string, error) { return "", os.ErrInvalid }
	t.Cleanup(func() { sharedDaemonResolveResponsibleSupervisor = original })

	_, err := renderSharedDaemonLaunchAgent("/opt/node", "/opt/codex", nil, "")
	if err == nil || !strings.Contains(err.Error(), "责任进程") {
		t.Fatalf("App 主程序不可解析时必须 fail closed：%v", err)
	}
}

// swiftConcatenatedLiteral 取出 Swift 源码里某个属性的全部字符串字面量并拼接。
// supervisor 脚本只含单引号，不必处理转义。
func swiftConcatenatedLiteral(source string, marker string) (string, bool) {
	index := strings.Index(source, marker)
	if index < 0 {
		return "", false
	}
	// 属性可能写成单行，也可能是多行 `+` 拼接。以“续行必须以 + 开头”界定作用域，
	// 避免把紧邻的下一个 static let 一起吞进来。
	lines := strings.Split(source[index+len(marker):], "\n")
	kept := lines[:1]
	for _, line := range lines[1:] {
		if !strings.HasPrefix(strings.TrimSpace(line), "+") {
			break
		}
		kept = append(kept, line)
	}
	block := strings.Join(kept, "\n")
	var builder strings.Builder
	for {
		open := strings.Index(block, `"`)
		if open < 0 {
			break
		}
		block = block[open+1:]
		close := strings.Index(block, `"`)
		if close < 0 {
			return "", false
		}
		builder.WriteString(block[:close])
		block = block[close+1:]
	}
	return builder.String(), true
}

// Swift supervisor 持有自己的脚本副本（不从命令行接收），而 agentd 在运行态按 Go
// 常量校验 node 进程命令行。两份正文一旦漂移，共享 daemon 会在验签处静默失败，
// 现象是实验模式怎么都连不上——这条测试把漂移拦在构建期。
func TestSharedDaemonResponsibleSupervisorContractMatchesSwift(t *testing.T) {
	raw, err := os.ReadFile(codexDaemonSupervisorSwiftPath)
	if err != nil {
		t.Fatalf("读取 Swift supervisor 源码失败：%v", err)
	}
	source := string(raw)

	script, ok := swiftConcatenatedLiteral(source, "static let nodeSupervisorScript =")
	if !ok {
		t.Fatal("Swift 源码里找不到 nodeSupervisorScript")
	}
	if script != sharedDaemonNodeSupervisorScript {
		t.Fatalf("supervisor 脚本两侧不一致：\nGo   : %s\nSwift: %s", sharedDaemonNodeSupervisorScript, script)
	}

	flag, ok := swiftConcatenatedLiteral(source, "static let flag =")
	if !ok {
		t.Fatal("Swift 源码里找不到 supervisor 旗标")
	}
	if flag != sharedDaemonResponsibleSupervisorFlag {
		t.Fatalf("supervisor 旗标两侧不一致：Go %q，Swift %q", sharedDaemonResponsibleSupervisorFlag, flag)
	}

	if team, ok := swiftConcatenatedLiteral(source, "static let openAITeamIdentifier ="); !ok ||
		team != sharedDaemonOpenAITeamIdentifier {
		t.Fatalf("OpenAI Team 两侧不一致：Go %q，Swift %q", sharedDaemonOpenAITeamIdentifier, team)
	}
}
