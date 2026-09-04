# Tailcat 与 Tailscale 对照测试

## 目标

在同一台移动设备、同一台 Mac 和同一网络条件下收集可复算的连接样本。测试只判断实际路径和连接生命周期，不把 DERP Home 当作当前数据路径。

## 方案

在“设置 → 连接测速”中打开“记录对照样本”。每次测速会保存以下匿名证据：

- 线路：Tailcat 或 Tailscale。
- 场景：冷连接、热连接或网络恢复。
- 实际路径：直连、Peer Relay、DERP 或未知。
- DERP 区域代码。只有格式正常的短区域代码会保存。
- Tailcat 启动耗时、应用层总耗时和各阶段耗时。
- Tailscale 使用 MagicDNS 还是 IP 候选。不会保存实际名称或 IP。
- 成功状态和失败阶段。不会保存原始错误文本。

应用会统计成功样本的中位数和 nearest-rank P95，并单独统计失败率。只有两条线路都为直连，或都经过同一区域 DERP 时，导出的 `matchedPaths` 才会产生对比项。

## 实现与执行

1. 固定移动设备、Mac、路由器位置和网络。关闭会改变路径的下载、VPN 和热点切换。
2. 打开“连接测速”，启用“记录对照样本”，然后清除旧样本。一次数据集只测试一组固定环境。
3. 选择“热连接”。保持 Tailcat 和 Tailscale 已连接，交替测试两条线路，各完成至少 20 次。
4. 选择“冷连接”。Tailcat 会在每次测试前重建客户端，并把重建时间计入端到端耗时。
5. 测试 Tailscale 冷连接前，在 Tailscale App 中断开并重新连接，随后立即返回 Mimi 测试。iOS 不允许 Mimi 强制重启其他 App 的 Network Extension，因此导出结果会标记为 `tailscale_system_managed`，不能声称是程序控制的完全相同冷启动。
6. 选择“网络恢复”。先切换 Wi-Fi 或蜂窝网络，再立即点击测试。该样本测量的是点击按钮到链路恢复的时间，不包含按钮点击前的系统网络切换时间。
7. 完成后导出 JSON。确认 Tailcat 和 Tailscale 各有至少 20 个冷连接样本和 20 个热连接样本。
8. 分别查看直连匹配组和同 DERP 区域匹配组。路径为 `unknown` 的样本只计入整体失败率，不用于同路径速度结论。

导出文件不包含公网 IP、Tailscale IP、MagicDNS 名称、Tailcat 地址、agentd Token、私钥、设备名称或业务内容。

## 风险与优化

- Tailscale Network Extension 的真实启动时刻由 iOS 管理。冷连接结果必须结合 `endpointCandidate`、第一个 `health` 阶段和 `tailscale_system_managed` 标记解读。
- Tailcat 冷连接会记录 `preparationMillis`；热连接不会把路径诊断的 DISCO Ping 算入应用层耗时。路径诊断在业务测速后执行，避免提前预热冷连接。
- 网络恢复的完整系统切换时间仍需真机外部计时或后续自动化支持。本工具不会把按钮点击前的时间写成恢复耗时。
- 未达到 20 次样本、路径不匹配或 DERP 区域不同，不应据此修改默认线路或宣传速度优势。
