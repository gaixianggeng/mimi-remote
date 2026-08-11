# Nightly 与正式发布

## 目标

`main` 有新提交时，每天北京时间 02:30 自动给官方仓库生成一个 Internal TestFlight Nightly；正式发布仍由维护者明确触发。Nightly 只服务于内测，不代表 App Store 审核或公开上架。

## 方案

- Nightly workflow 先在无签名凭证的步骤中确认官方仓库、`refs/heads/main`、事件 SHA、checkout 的 `HEAD` 与最新 `origin/main` 完全一致。
- 同一 SHA 已有成功 Nightly 时，普通定时或手工触发只做成功的 skip；需要重发时手工选择 `force_publish`。
- 确定需要发布后，先在轻量 Ubuntu job 中只检查 ASC、主 App / Widget profile、分发证书与临时 Keychain Secrets 是否齐全；缺失配置会在启动 macOS Simulator 回归前失败。profile 内容、App Group、Team、Bundle ID、证书和签名身份仍由后续发布 job 完整校验。
- 发布 job 复用 iOS CI 的归档、签名和 `ios_testflight_ci.sh`，成功后保存 `nightly-testflight-<SHA>` evidence artifact 30 天。
- 正式 iOS 候选通过 iOS CI 的 `workflow_dispatch` 和 `publish_app_store` 手工触发。正式 Mac、agentd、Windows 由维护者从已经进入 `main` 的 commit 创建并推送 `vX.Y.Z` tag，再发送 `repository_dispatch:release` 并传入该 tag；tag push 本身不读取发布 Secret。GitHub 固定从默认分支加载 Release workflow，workflow 再在不读取 Secret 的轻量 job 中核对官方仓库、受信 main SHA、目标 tag 与 `origin/main` 可达性，最后才允许签名和发布 job 进入 `production-release` Environment。

## 实现

Nightly 的 What to Test 只包含北京时间日期、短 SHA 和清洗后的 commit title。App 的 marketing version 与 host 的 `v*` 版本线独立；build number 继续由 App Store Connect 预检分配。Windows 签名和真实 Runtime 不属于 Nightly 的阻塞链路。

## 风险与优化

- 同一 SHA 的并发运行由固定 concurrency 串行化；已有成功 Nightly run 时默认跳过。如果上传完成后 caller 的最终汇总因基础设施故障失败，也只接受同时绑定原 Nightly workflow run、head SHA 和 evidence JSON 的 artifact，不能仅凭同名 artifact 跳过。发布 Secret 缺失时只会输出缺失的变量名，不输出内容，也不会启动昂贵 iOS 回归；Apple 处理、profile 内容或签名凭证校验失败时，由维护者检查日志后选择 `force_publish` 重试。
- Nightly 不会替代本地恢复入口；需要指定 commit 或离线排查时，继续使用 [`git testflight-push`](local-testflight.md)。
- 当前不包含 App Store 审核、公开上架、rollback attestation 或额外 ASC 编排；真实需求出现后再单独评估。
