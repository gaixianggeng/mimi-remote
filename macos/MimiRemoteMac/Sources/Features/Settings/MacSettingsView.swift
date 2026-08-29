import SwiftUI

struct MacSettingsView: View {
    let store: HostStore
    @Environment(\.openWindow) private var openWindow
    @State private var confirmsRestore = false

    var body: some View {
        Form {
            Section("启动") {
                Toggle("登录 Mac 时启动菜单栏和服务", isOn: Binding(
                    get: { store.launchesAtLogin },
                    set: { enabled in
                        Task { await store.setLaunchAtLogin(enabled) }
                    }
                ))
                Button("打开系统登录项设置…") {
                    store.openLoginItemsSettings()
                }
            }

            Section("服务") {
                LabeledContent("当前状态", value: store.lifecycle.title)
                LabeledContent("运行方式", value: ownerTitle)
                if let status = store.status {
                    LabeledContent("Endpoint", value: status.endpoint)
                    LabeledContent("agentd 版本", value: status.version)
                }
                if store.canRestoreHomebrew {
                    Button("停止 App 服务并恢复 Homebrew…", role: .destructive) {
                        confirmsRestore = true
                    }
                }
            }

            Section("实验功能") {
                Button(ExperimentMenuRouting.menuTitle) {
                    // 通用设置保留唯一导航入口；实验配置只在实验功能窗口维护。
                    openWindow(id: ExperimentMenuRouting.windowID)
                }
                Text("Claude 实验开关和状态集中在同一窗口。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("文件访问") {
                Button("打开完全磁盘访问权限设置…") {
                    store.openFullDiskAccessSettings()
                }
                Text("只有 agentd 需要读取 macOS 保护的目录时，才需要授予完全磁盘访问权限。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("隐私") {
                Text("Mimi Remote Mac 不上传日志、代码、Token 或使用数据。长期 Token 只保存在 agentd 的私有配置中，App 只处理短期配对票据。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scenePadding()
        .frame(width: 500, height: 640)
        .alert("恢复 Homebrew 服务？", isPresented: $confirmsRestore) {
            Button("取消", role: .cancel) {}
            Button("停止 App 服务并恢复", role: .destructive) {
                Task { await store.restoreHomebrew() }
            }
        } message: {
            Text("切换期间移动设备会短暂断开；Homebrew 启动失败时会自动恢复 App 服务。")
        }
    }

    private var ownerTitle: String {
        switch store.owner {
        case .none: "未运行"
        case .macApp: "Mimi Remote Mac"
        case .homebrew: "Homebrew"
        }
    }
}
