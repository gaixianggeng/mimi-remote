import AppKit
import SwiftUI

struct DashboardView: View {
    let store: HostStore
    /// 首次启动时由系统直接弹出这个窗口；菜单栏 App 不会自动切到前台，窗口会落在别的 App 后面。
    var activatesOnAppear = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HostStatusHeader(lifecycle: store.lifecycle)

                switch store.lifecycle {
                case .notConfigured:
                    OnboardingView(store: store)
                case .migrationRequired:
                    MigrationView(store: store)
                default:
                    ServiceOverviewView(store: store)
                }

                if let lastError = store.lastError {
                    Text(lastError)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .padding(24)
        }
        .navigationTitle("Mimi Remote Mac")
        .onAppear {
            guard activatesOnAppear else { return }
            DispatchQueue.main.async {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
    }
}

private struct ServiceOverviewView: View {
    let store: HostStore
    @Environment(\.openWindow) private var openWindow
    @State private var confirmsRestore = false

    var body: some View {
        VStack(spacing: 14) {
            if let status = store.status {
                InfoCard("连接") {
                    KeyValueRow(key: "Endpoint", value: status.endpoint)
                    KeyValueRow(key: "版本", value: status.version)
                    KeyValueRow(key: "已授权项目", value: "\(status.projects)")
                    KeyValueRow(key: "运行方式", value: store.owner == .macApp ? "Mimi Remote Mac" : "Homebrew")
                }
            }

            HStack {
                // 设置完成后用户最需要的是二维码；状态页也给一个直达入口，不必回菜单栏找。
                Button("显示配对二维码") { openWindow(id: AppWindow.pairing.rawValue) }
                    .buttonStyle(.borderedProminent)
                Button("刷新状态") { Task { await store.refresh() } }
                Button("重启服务") { Task { await store.restartService() } }
                    .disabled(store.owner != .macApp || store.isBusy)
                Spacer()
                if store.canRestoreHomebrew {
                    Button("恢复 Homebrew…", role: .destructive) {
                        confirmsRestore = true
                    }
                }
            }
            CodexRuntimeUpdateNotice(store: store, showsCurrentVersion: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("恢复 Homebrew 服务？", isPresented: $confirmsRestore) {
            Button("取消", role: .cancel) {}
            Button("停止 App 服务并恢复", role: .destructive) {
                Task { await store.restoreHomebrew() }
            }
        } message: {
            Text("切换期间移动设备会短暂断开；Homebrew 启动失败时会自动恢复 App 服务。")
        }
    }
}

private struct MigrationView: View {
    let store: HostStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsTakeover = false

    var body: some View {
        InfoCard("发现现有 Homebrew 服务") {
            Text("接管会复用现有配置和 iPad Token，停止 Homebrew 后台服务，再启动 App 内签名的 agentd。Homebrew formula 会保留，接管失败时自动恢复。")
                .foregroundStyle(.secondary)
            HStack {
                Button("确认并接管") { confirmsTakeover = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isBusy)
                Button("先保持现状") { dismiss() }
            }
        }
        .alert("接管 Homebrew 服务？", isPresented: $confirmsTakeover) {
            Button("取消", role: .cancel) {}
            Button("开始接管") {
                Task { await store.takeOverHomebrew() }
            }
        } message: {
            Text("切换期间 iPhone 和 iPad 会短暂断开；失败时会自动恢复旧服务。")
        }
    }
}

#if DEBUG
    #Preview("服务可用") {
        DashboardView(store: .preview(.ready))
    }

    #Preview("首次设置") {
        DashboardView(store: .preview(.notConfigured))
    }
#endif
