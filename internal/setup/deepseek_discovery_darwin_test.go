//go:build darwin

package setup

import "testing"

func TestParseDeepSeekLaunchctlPrintRequiresRunningCurrentJobFields(t *testing.T) {
	raw := []byte(`gui/501/ai.deepseek.harness.web = {
	state = running
	stdout path = /Users/example/Library/Logs/deepseek-harness.log
	LWCR = {
		"reqs": {
			"fixture": true
		}
	}
	pid = 4321
	resource coalition = {
		ID = 123
		state = active
	}
	jetsam coalition = {
		ID = 456
		state = active
	}
}`)
	pid, path, err := parseDeepSeekLaunchctlPrint(raw)
	if err != nil || pid != 4321 || path != "/Users/example/Library/Logs/deepseek-harness.log" {
		t.Fatalf("launchctl 解析不符：pid=%d path=%q err=%v", pid, path, err)
	}
	for _, invalid := range [][]byte{
		[]byte("job = {\n\tstate = exited\n\tstdout path = /tmp/log\n\tpid = 1\n\tnested = {\n\t\tstate = running\n\t}\n}"),
		[]byte("job = {\n\tstate = running\n\tstdout path = relative.log\n\tpid = 1\n}"),
		[]byte("job = {\n\tstate = running\n\tstdout path = /tmp/log\n\tpid = 0\n}"),
	} {
		if _, _, err := parseDeepSeekLaunchctlPrint(invalid); err == nil {
			t.Fatalf("应拒绝非运行 job：%q", invalid)
		}
	}
}

func TestParseLastDeepSeekLaunchLineUsesLatestOfficialLine(t *testing.T) {
	raw := []byte("dsh web: http://127.0.0.1:4000/?token=old\nnoise\ndsh web: http://127.0.0.1:5000/?token=new\n")
	candidate, err := parseLastDeepSeekLaunchLine(raw)
	if err != nil {
		t.Fatal(err)
	}
	if candidate.BaseURL != "http://127.0.0.1:5000" || candidate.Token != "new" {
		t.Fatalf("必须使用最后一条正式启动输出：%+v", candidate)
	}

	malformedLatest := append(raw, []byte("dsh web: https://example.invalid/?token=bad\n")...)
	latest, err := parseLastDeepSeekLaunchLine(malformedLatest)
	if err != nil {
		t.Fatal(err)
	}
	latest.PID = 1
	if err := validateDiscoveredDeepSeekCandidate(latest); err == nil {
		t.Fatalf("不得回退到旧的合法日志行：%+v", latest)
	}
}

func TestParseDeepSeekStartupLineIgnoresBrowserNoticeAndLANAnnotation(t *testing.T) {
	raw := []byte("dsh web: http://127.0.0.1:3080/?token=fixture (LAN: http://192.0.2.1:3080/)\n" +
		"dsh web: opening the default browser; pass --no-open to disable\n")
	candidate, err := parseLastDeepSeekLaunchLine(raw)
	if err != nil {
		t.Fatal(err)
	}
	if candidate.BaseURL != "http://127.0.0.1:3080" || candidate.Token != "fixture" {
		t.Fatal("提示行和 LAN 尾注不能覆盖回环启动链接")
	}
}
