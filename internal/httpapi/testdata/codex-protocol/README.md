# Codex app-server 协议快照

## 目标

这里仅保存项目固定 Codex CLI 版本，以及 `ClientRequest`、`ServerRequest`、`ServerNotification` 的方法名列表。完整 JSON Schema 由检查脚本临时生成，不提交到仓库。

当前快照基于 Codex CLI `0.144.2`：

- ClientRequest：122 个方法
- ServerRequest：11 个方法
- ServerNotification：68 个方法

## 检查

```bash
bash ./scripts/check-codex-protocol.sh
```

脚本会检查本机 Codex CLI 版本，生成实验性 app-server schema，稳定排序方法名并与快照执行 diff。临时文件会在退出时清理。

## 更新

只有在明确升级 Codex 并评估协议变化后才更新快照：

```bash
npm install --global @openai/codex@x.y.z
bash ./scripts/check-codex-protocol.sh --update
bash ./scripts/check-codex-protocol.sh
```

升级到其他版本时，还必须同步修改 `.github/workflows/codex-protocol.yml` 中固定的 npm 版本。不要直接接受 diff；应先确认新增、删除或重命名的方法是否影响 Go Gateway 和移动端。
