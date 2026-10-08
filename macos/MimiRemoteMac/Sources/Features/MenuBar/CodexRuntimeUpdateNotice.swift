import AppKit
import SwiftUI

struct CodexRuntimeUpdateNotice: View {
    let store: HostStore
    var showsCurrentVersion = false

    private var update: CodexRuntimeUpdateStore { store.codexRuntimeUpdate }
    private var canInspect: Bool { store.owner == .macApp && store.codexEnabled }
    private var repairsConnectionSettings: Bool {
        update.versions?.updateAvailable == false && update.versions?.featureMismatch == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if canInspect, let versions = update.versions, versions.needsRecovery || update.isUpdating {
                Label(
                    repairsConnectionSettings ? "Codex 连接设置需要修复" : "Codex 已更新，正在使用旧版",
                    systemImage: repairsConnectionSettings ? "wrench.and.screwdriver" : "arrow.triangle.2.circlepath"
                )
                    .font(.callout.weight(.medium))
                if !repairsConnectionSettings {
                    Text("正在使用 \(versions.runningVersion) · 已安装 \(versions.installedVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(recoveryDescription(for: versions))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                connectionGuidance(versions.connections)
                HStack(spacing: 8) {
                    if update.isUpdating { ProgressView().controlSize(.small) }
                    Button(actionTitle) {
                        confirmUpdate()
                    }
                    .disabled(store.isBusy || update.isChecking)
                    Button(update.isChecking ? "正在检查…" : "重新检查") { Task { await update.refresh() } }
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
               showsCurrentVersion || update.versions?.needsRecovery == true || update.updateFailed {
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

    private var actionTitle: String {
        if repairsConnectionSettings {
            return update.isUpdating ? "正在修复…" : "修复连接"
        }
        return update.isUpdating ? "正在切换…" : "切换到新版"
    }

    private func recoveryDescription(for versions: CodexRuntimeVersions) -> String {
        if repairsConnectionSettings {
            return "可在确认后断开共享连接并修复连接设置。正在执行的任务可能中断，已保存的会话记录会保留。"
        }
        if versions.featureMismatch == true {
            return "可在确认后直接断开共享连接并切换，连接设置也会一并修复。正在执行的任务可能中断，已保存的会话记录会保留。"
        }
        return "可在确认后直接断开共享连接并切换。正在执行的任务可能中断，已保存的会话记录会保留。"
    }

    @ViewBuilder
    private func connectionGuidance(_ connections: CodexRuntimeConnections?) -> some View {
        if let connections, connections.total > 0 {
            Text("当前共享连接：Mimi \(connections.mimi) 个 · Codex \(connections.codex) 个 · 其他 \(connections.other) 个")
                .font(.caption)
        } else if connections == nil {
            Text("暂时无法统计共享连接，\(repairsConnectionSettings ? "修复" : "切换")前仍会询问确认。")
                .font(.caption)
        }
    }

    private func confirmUpdate() {
        // 菜单弹窗关闭后再展示应用级确认，避免临时 View 销毁导致确认丢失。
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = repairsConnectionSettings ? "断开并修复 Codex 连接？" : "断开连接并切换 Codex？"
            let completedAction = repairsConnectionSettings ? "修复" : "切换"
            alert.informativeText = "Mimi、终端和 Desktop 的共享连接会短暂断开。正在执行的任务可能中断，请在\(completedAction)后检查任务状态。已保存的会话记录会保留。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: repairsConnectionSettings ? "断开并修复连接" : "断开并切换")
            alert.addButton(withTitle: "取消")
            alert.buttons.first?.hasDestructiveAction = true
            NSApplication.shared.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            Task {
                await update.update(restart: true)
                await store.refresh()
            }
        }
    }
}
