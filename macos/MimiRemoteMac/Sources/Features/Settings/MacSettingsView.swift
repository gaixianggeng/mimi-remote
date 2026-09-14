import SwiftUI

struct MacSettingsView: View {
    let store: HostStore
    let updates: AppUpdateStore
    @Environment(\.openWindow) private var openWindow
    @State private var confirmsRestore = false

    var body: some View {
        Form {
            Section("软件更新") {
                AppUpdateView(updates: updates)
            }

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
                LabeledContent("照片图库", value: store.photosAccess.title)
                switch store.photosAccess {
                case .notDetermined:
                    Button("允许访问照片…") {
                        Task { await store.requestPhotosAccess() }
                    }
                case .denied, .restricted:
                    Button("打开照片隐私设置…") {
                        Task { await store.requestPhotosAccess() }
                    }
                case .authorized, .limited:
                    EmptyView()
                }
                Text(photosAccessCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("打开完全磁盘访问权限设置…") {
                    store.openFullDiskAccessSettings()
                }
                Text(fullDiskAccessCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onAppear {
                store.refreshPhotosAccess()
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

    private var photosAccessCaption: String {
        if store.owner == .homebrew {
            return "当前由 Homebrew 运行 agentd，这里的照片权限不会作用于它；需要预览“照片”里的图片时，请在“完全磁盘访问”中添加 agentd。"
        }
        return "在 Mac 上把“照片”里的图片拖进会话后，iPhone 或 iPad 预览这些图片需要该权限。Mimi 不会修改或上传照片。"
    }

    private var fullDiskAccessCaption: String {
        if store.owner == .homebrew {
            return "Homebrew 版需要在列表中添加 /opt/homebrew/opt/mimi-remote/bin/agentd。"
        }
        return "只有需要读取 Mail、Safari 等其他 App 的数据时，才需要在“完全磁盘访问”中添加 Mimi Remote Mac。桌面、文稿和下载会在首次访问时由系统单独询问。"
    }

    private var ownerTitle: String {
        switch store.owner {
        case .none: "未运行"
        case .macApp: "Mimi Remote Mac"
        case .homebrew: "Homebrew"
        }
    }
}
