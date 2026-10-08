import SwiftUI

struct CodexRuntimeUpdateNotice: View {
    let store: HostStore
    var showsCurrentVersion = false

    private var update: CodexRuntimeUpdateStore { store.codexRuntimeUpdate }
    private var canInspect: Bool { store.owner == .macApp && store.codexEnabled }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if canInspect, let versions = update.versions, versions.updateAvailable || update.isUpdating {
                Label("Codex 已更新，正在使用旧版", systemImage: "arrow.triangle.2.circlepath")
                    .font(.callout.weight(.medium))
                Text("正在使用 \(versions.runningVersion) · 已安装 \(versions.installedVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("结束任务并关闭共享会话后切换。会话记录会保留，连接会短暂重连。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if update.isUpdating { ProgressView().controlSize(.small) }
                    Button(update.isUpdating ? "正在切换…" : "切换到新版") {
                        Task {
                            await update.update()
                            await store.refresh()
                        }
                    }
                    .disabled(store.isBusy || update.isChecking)
                    Button("刷新状态") { Task { await update.refresh() } }
                        .disabled(store.isBusy || update.isChecking)
                }
                .controlSize(.small)
            } else if canInspect, let notice = update.notice {
                Label(notice, systemImage: "checkmark.circle")
                    .font(.caption)
            } else if canInspect, showsCurrentVersion, let versions = update.versions {
                Text("正在使用 Codex \(versions.runningVersion) · 已安装 \(versions.installedVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if canInspect, let error = update.error,
               showsCurrentVersion || update.versions?.updateAvailable == true || update.updateFailed {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if update.versions == nil {
                    Button("重新检查 Codex") { Task { await update.refresh() } }
                        .disabled(store.isBusy || update.isChecking)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .task(id: canInspect) {
            if canInspect { await update.refresh() }
        }
    }
}
