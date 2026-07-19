# Mimi Remote Agent Notice

## 目标

这个文件说明公开后端仓库 `mimi-remote` 的归属、第三方品牌边界和开源使用方式。

## 项目归属

Mimi Remote Agent 是独立开发的第三方服务。它运行在用户自己的开发机上，并连接用户本机安装的 Codex CLI / app-server 环境。

本项目不隶属于 OpenAI，也没有获得 OpenAI 的赞助、背书或官方授权。`Codex`、`OpenAI` 等名称只用于描述兼容的用户自有工具链。

## 开源许可

Copyright (c) 2026 Gaixiang Geng

本公开发布镜像中实际包含的 `agentd` 后端代码使用 GNU GPLv3，并依据 GPLv3 第 7 节授予通过 Apple App Store 和 Google Play 分发的额外许可。完整条款见 [LICENSE](LICENSE)。移动客户端源码采用相同协议，位于完整开源仓库 [gaixianggeng/codex-ipad-agent](https://github.com/gaixianggeng/codex-ipad-agent)。

商业使用并未被禁止，但分发修改版或二进制时仍须遵守 GPLv3，包括保留版权与许可声明、标记修改，并向接收者提供对应源码和同等许可。此前已经明确以 MIT License 发布的历史版本继续受其原有许可。

## 第三方依赖

Go runtime 和 Go module 依赖保留各自的上游许可证。完整版权声明和许可证正文见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)，该文件会随 `agentd` 发布压缩包分发。

运行时还需要用户自行安装和登录 Codex CLI / app-server。本仓库不打包用户的 Codex 凭证，也不托管第三方服务账号。

## 品牌边界

本项目不会把自己宣传为任何商业产品的免费替代品，也不以复刻其他产品的 UI、图标、截图或宣传文案为目标。
