# Mimi Remote Agent Notice

## 目标

这个文件说明公开后端仓库 `mimi-remote` 的归属、第三方品牌边界和开源使用方式。

## 项目归属

Mimi Remote Agent 是独立开发的第三方服务。它运行在用户自己的开发机上，并连接用户本机安装的 Codex CLI / app-server 环境。

本项目不隶属于 OpenAI，也没有获得 OpenAI 的赞助、背书或官方授权。`Codex`、`OpenAI` 等名称只用于描述兼容的用户自有工具链。

## 开源许可

本公开仓库中实际包含的 `agentd` 后端代码使用 MIT License 发布，完整条款见 [LICENSE](LICENSE)。未包含在本仓库中的移动客户端源码不属于该开源范围。

MIT 许可允许使用、修改和分发代码，但分发本项目或其重要部分时，需要保留原始版权声明和许可证文本。

## 第三方依赖

Go runtime 和 Go module 依赖保留各自的上游许可证。完整版权声明和许可证正文见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)，该文件会随 `agentd` 发布压缩包分发。

运行时还需要用户自行安装和登录 Codex CLI / app-server。本仓库不打包用户的 Codex 凭证，也不托管第三方服务账号。

## 品牌边界

本项目不会把自己宣传为任何商业产品的免费替代品，也不以复刻其他产品的 UI、图标、截图或宣传文案为目标。
