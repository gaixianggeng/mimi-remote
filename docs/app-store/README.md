# Mimi Remote App Store 提交材料

## 目标

本目录保存可复制到 App Store Connect 的中英文元数据和审核说明，确保商店描述、App 实际能力、隐私政策与审核环境保持一致。

## 方案

- App 名称：简体中文与英文均为 `Mimi Remote`
- 主类别：`Developer Tools / 开发者工具`
- 版本与发布构建：提交时选择包含 Mimi 托管连接的版本；正式归档由发布脚本查询 App Store Connect 后确认构建号可用，不复用旧版元数据提交的构建假设。
- 隐私标签：按 [App 隐私填写依据](app-privacy-labels.md)披露订阅、设备标识和连接诊断等数据，并同时复核已有推送服务；不能继续填写“开发者不收集数据”。
- 价格：App 与电脑端免费开源，局域网、Tailscale 和自建 Tailcat 继续免费。可选的 Mimi 托管连接自动续期订阅：月付 ¥9.9 / US$1.99，年付 ¥68 / US$9.99，其余地区由 Apple 换算。两个方案均有 7 天免费试用，每个 Apple ID 在订阅组内仅一次；无终身买断，关闭家人共享，向所有地区提供。
- 名额与恢复：每个订阅最多 3 台电脑、5 台手机或平板，可在 App 内移除设备。无需 Mimi 账号；同一 Apple ID 可恢复权益，不同步地址、私钥或电脑访问凭据，新手机或平板需重新接入每台电脑。
- 中国大陆：按“用户自托管开发工作台与可选托管连接”准备。截图允许在真实 App 界面内出现用户实际可选的第三方 Runtime 名称与图标；宣传标题、商店文案与免责声明必须保持独立第三方定位。

公开 URL：

- Marketing URL：首个中国大陆版本留空，避免把 README 中的开发者兼容性说明误当作商店宣传元数据。
- Privacy Policy URL：<https://github.com/gaixianggeng/mimi-remote/blob/main/docs/privacy-policy.md>
- Support URL：<https://github.com/gaixianggeng/mimi-remote/blob/main/docs/support.md>
- Terms URL：<https://github.com/gaixianggeng/mimi-remote/blob/main/docs/terms-of-use.md>

## 实现

- `en-US/` 与 `zh-Hans/`：名称、副标题、推广文本、关键词、描述和版本说明。
- `app-review-notes.md`：提交到 App Review Information 的英文说明模板。
- `review-environment-checklist.md`：审核专用 Mac 的最小安全闭环。
- `china-mainland-submission-checklist.md`：中国大陆地区合规、账号和 App Store Connect 核对清单。
- `app-privacy-labels.md`：托管连接新增数据的问卷分类、用途与公开代码依据。

订阅提交前必须确认付费 App 协议、税务与收款信息有效，为两个订阅提供审核截图，并配置和测试生产环境 App Store Server Notifications 地址。同时准备 Sandbox 购买、恢复购买、设备移除与运行 Mimi 的电脑配对演示；视频链接填入审核备注占位符。商品名称、时长、价格、试用、续费和取消说明及法律链接须同时出现在购买界面与对应商店材料中。

提交时必须把模板中的占位符替换成审核专用值；Token、真实 Endpoint、电话号码和个人项目路径不得提交到 Git。

## 风险与优化

- GitHub 文档是当前最低维护成本方案。正式上架后可迁移到自有域名，但应先保证新旧 URL 都能长期访问。
- App Store 截图必须展示真实 App 使用界面，不应只展示连接页或宣传图。
- MIM-233 截图保留 App 内真实的 Runtime 名称与图标，这是当前确认的提交策略；审核仍可能要求补充授权说明或调整素材。公开商店元数据继续使用中性的功能描述，并明确不隶属或受第三方背书。
- 中国大陆可用性还取决于账号主体信息、可能适用的 App/ICP 备案以及 Apple 审核结果；本文档不替代适用法律的专业意见。
- 消息通知默认开启（#419）、自建 Tailcat 第三方中继、Mimi 托管连接和新会话默认完全访问，都会影响商店材料。托管连接中继由开发者运营，无法读取端到端加密的工作内容；不要再使用“开发者不运营中继”的笼统表述。
- 这些文档按托管连接已开放的状态起草，正式开放前不合并。维护者需确认法律主体、联系邮箱、控制面记录与生产日志的保留政策，并补齐演示视频。提交时再同步 App Store Connect；本次仅更新仓库文档。
