// Package tailcattest 提供 Tailcat 集成测试共用的辅助函数，只供测试导入。
package tailcattest

import (
	"testing"

	"github.com/tailscale/tailcat"
	"tailscale.com/envknob"
)

const alwaysUseDERPKnob = "TS_DEBUG_ALWAYS_USE_DERP"

// ForceDERP 关闭本进程内之后新建的 Tailcat 引擎的 UDP，让对端流量只能经过 DERP。
//
// magicsock 在包初始化时用 envknob.RegisterBool 缓存这个开关，t.Setenv 只改
// 环境变量、不刷新缓存，同机两端仍会直连。必须经 envknob 修改，并在启动 Host
// 或 Forwarder 之前调用；测试结束时自动恢复，不能用于并行测试。
func ForceDERP(t testing.TB) {
	t.Helper()
	envknob.SetenvForTest(t, alwaysUseDERPKnob, "1")
	// RegisterBool 对同名开关返回同一份缓存，读到的就是 magicsock 绑定 UDP 时的判断依据。
	if !envknob.RegisterBool(alwaysUseDERPKnob)() {
		t.Fatalf("%s 没有在 envknob 缓存中生效，UDP 仍会开启", alwaysUseDERPKnob)
	}
}

// AddressRegionCode 返回 Tailcat 地址内嵌中继的区域代码，即 DiscoPing 经该中继时报告的值。
// 地址编码会去掉原始 RegionCode，解码时由 Tailcat 重新生成，所以不能直接比较测试区域的配置。
func AddressRegionCode(t testing.TB, address string) string {
	t.Helper()
	info, err := tailcat.ParseAddr(tailcat.Addr(address))
	if err != nil {
		t.Fatal(err)
	}
	if len(info.Region) != 1 || info.Region[0].RegionCode == "" {
		t.Fatalf("地址没有内嵌唯一的中继区域：%+v", info.Region)
	}
	return info.Region[0].RegionCode
}
