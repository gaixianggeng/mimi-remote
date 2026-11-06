package httpapi

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestTailcatRelayTransactionFailureRestoresManagedConnection(t *testing.T) {
	binary := buildModeTestSidecar(t)
	for _, target := range []string{"", "https://broken.example.invalid/map"} {
		t.Run(target, func(t *testing.T) {
			s, c := newModeTestHost(t, binary, "https://old.example.invalid/map", true)
			if _, err := c.ConfigureMode(context.Background(), true); err != nil {
				t.Fatal(err)
			}
			seedModeTestPolicy(t, c, s)
			before := s.Status(context.Background())
			identity, err := snapshotTailcatIdentityState(s.stateDir)
			if err != nil {
				t.Fatal(err)
			}
			policy := c.state
			if err := os.WriteFile(filepath.Join(s.stateDir, "fail-start-url"), []byte(target), 0o600); err != nil {
				t.Fatal(err)
			}
			// 空值的失败标记也用于默认中转，验证从托管退出不会先被提交。
			_, err = c.ConfigureRelay(context.Background(), target)
			if err == nil {
				t.Fatal("目标中转启动失败时不能返回成功")
			}
			after := s.Status(context.Background())
			if !after.Running || after.Mode != before.Mode || after.DERPMapURL != before.DERPMapURL || after.PublicKey != before.PublicKey {
				t.Fatalf("失败后未恢复原托管连接：before=%+v after=%+v", before, after)
			}
			restored, err := snapshotTailcatIdentityState(s.stateDir)
			if err != nil || !reflect.DeepEqual(identity, restored) {
				t.Fatal("失败后身份未完整恢复", err)
			}
			if !reflect.DeepEqual(policy, c.state) {
				t.Fatal("失败后注册策略发生变化")
			}
			persisted := readModeTestConfig(t, s.configPath)
			if persisted.Tailcat.ConnectionMode() != config.TailcatModeManaged || persisted.Tailcat.DERPMapURL != before.DERPMapURL {
				t.Fatal("失败后持久配置发生变化")
			}
		})
	}
}

func TestTailcatRelayTransactionCommitsTarget(t *testing.T) {
	binary := buildModeTestSidecar(t)
	for _, target := range []string{"", "https://custom.example.invalid/map"} {
		t.Run(target, func(t *testing.T) {
			s, c := newModeTestHost(t, binary, "https://old.example.invalid/map", true)
			if _, err := c.ConfigureMode(context.Background(), true); err != nil {
				t.Fatal(err)
			}
			seedModeTestPolicy(t, c, s)
			status, err := c.ConfigureRelay(context.Background(), target)
			if err != nil {
				t.Fatal(err)
			}
			if status.Mode != config.TailcatModeSelfHosted || status.DERPMapURL != target || !status.Running {
				t.Fatalf("目标未生效：%+v", status)
			}
			if c.state.HostDeviceToken != "" {
				t.Fatal("退出托管后应清空旧注册")
			}
			persisted := readModeTestConfig(t, s.configPath)
			if persisted.Tailcat.ConnectionMode() != config.TailcatModeSelfHosted || persisted.Tailcat.DERPMapURL != target {
				t.Fatal("目标未持久化")
			}
			again, err := c.ConfigureRelay(context.Background(), target)
			if err != nil || again.PublicKey != status.PublicKey {
				t.Fatal("相同目标应保持身份幂等", err)
			}
		})
	}
}
