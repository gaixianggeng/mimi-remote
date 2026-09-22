import SwiftUI

struct DiagnosticsView: View {
    let store: HostStore
    @State private var confirmsCodexSessionRepair = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HostStatusHeader(lifecycle: store.lifecycle, compact: true)
                Button("重新检查") { Task { await store.runDoctor(fix: false) } }
                Button("修复安全问题") { Task { await store.runDoctor(fix: true) } }
                    .disabled(store.isBusy)
                Button("修复共享运行环境…") { confirmsCodexSessionRepair = true }
                    .disabled(store.isBusy || store.owner != .macApp)
                Button("登录项设置…") { store.openLoginItemsSettings() }
            }
            .padding(18)

            Divider()

            HSplitView {
                List(store.doctor?.checks ?? []) { check in
                    DiagnosticCheckRow(check: check)
                }
                .frame(minWidth: 300)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("最近日志")
                            .font(.headline)
                        Spacer()
                        Button("在 Finder 中显示") { store.revealLogFile() }
                    }
                    if store.recentLogs.isEmpty {
                        ContentUnavailableView(
                            "暂无 App 托管日志",
                            systemImage: "doc.text",
                            description: Text("完成接管并启动服务后，这里会显示最近 200 行。")
                        )
                    } else {
                        ScrollView {
                            Text(store.recentLogs.joined(separator: "\n"))
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(16)
                .frame(minWidth: 360)
            }

            if !store.appliedFixes.isEmpty {
                Divider()
                Text("已修复：\(store.appliedFixes.joined(separator: "；"))")
                    .font(.caption)
                    .foregroundStyle(Color.mimiPrimary)
                    .padding(10)
            }

            if let notice = store.codexSessionRepairNotice {
                Divider()
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(Color.mimiPrimary)
                    .padding(10)
            }

            if let error = store.lastError {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(10)
            }
        }
        .confirmationDialog(
            "修复共享运行环境？",
            isPresented: $confirmsCodexSessionRepair,
            titleVisibility: .visible
        ) {
            Button("停止服务并修复", role: .destructive) {
                Task { await store.repairSharedCodexRuntime() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请先结束所有共享的 Codex 任务和其他 Mimi 活动任务，并关闭 Codex Desktop 的 SSH 共享页面。此操作不会修改钥匙串授权或删除任务历史。检测到活动任务或其他连接时会拒绝修复。")
        }
        .task {
            await store.runDoctor(fix: false)
            await store.loadRecentLogs()
        }
    }
}

private struct DiagnosticCheckRow: View {
    let check: AgentCheck

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: check.ok ? "checkmark.circle.fill" : check.isWarning ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
                .foregroundStyle(check.ok ? Color.mimiPrimary : check.isWarning ? Color.orange : Color.red)
            VStack(alignment: .leading, spacing: 3) {
                Text(check.name)
                    .font(.headline)
                Text(check.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let fix = check.fix, !check.ok {
                    Text(fix)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
