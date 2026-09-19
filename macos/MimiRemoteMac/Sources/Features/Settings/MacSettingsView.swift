import SwiftUI

struct MacSettingsView: View {
    let store: HostStore
    let updates: AppUpdateStore
    @Environment(\.openWindow) private var openWindow
    @State private var confirmsRestore = false
    @State private var confirmsTailcatReset = false
    @State private var derpMapURL = ""

    var body: some View {
        TabView {
            general.tabItem { Label("通用", systemImage: "gearshape") }
            agentSettings.tabItem { Label("AI Agent", systemImage: "sparkles") }
            connections.tabItem { Label("连接方式", systemImage: "network") }
            fileAccess.tabItem { Label("文件访问", systemImage: "folder") }
            service.tabItem { Label("服务", systemImage: "server.rack") }
        }
        .padding(16)
        .frame(width: 620, height: 650)
        .task { await store.refreshModules(); derpMapURL = store.tailcatDERPMapURL }
        .alert("恢复 Homebrew 服务？", isPresented: $confirmsRestore) {
            Button("取消", role: .cancel) {}
            Button("停止 App 服务并恢复", role: .destructive) { Task { await store.restoreHomebrew() } }
        } message: {
            Text("切换期间移动设备会断开；Homebrew 启动失败时会尝试恢复 App 服务。")
        }
        .alert("重置 Tailcat 配对？", isPresented: $confirmsTailcatReset) {
            Button("取消", role: .cancel) {}
            Button("重置", role: .destructive) { Task { await store.resetTailcat() } }
        } message: {
            Text("这会使现有 Tailcat 配对失效，设备需要重新扫码。普通开关不会执行此操作。")
        }
    }

    private var general: some View {
        Form {
            Section("软件更新") { AppUpdateView(updates: updates) }
            Section("启动") {
                Toggle("登录 Mac 时启动菜单栏和服务", isOn: Binding(
                    get: { store.launchesAtLogin },
                    set: { value in Task { await store.setLaunchAtLogin(value) } }
                ))
                Button("打开系统登录项设置…") { store.openLoginItemsSettings() }
            }
            Section("隐私") {
                Text("Mimi Remote Mac 不上传日志、代码、Token 或使用数据。长期 Token 只保存在 agentd 的私有配置中，App 只处理短期配对票据。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private var agentSettings: some View {
        Form {
            Section {
                ModuleGroupView(store: store, agents: true)
                Text("点击 Agent 查看版本、认证与独立额度。开关表示启用意图，不代表已经登录或可用。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            feedback
        }.formStyle(.grouped)
    }

    private var connections: some View {
        Form {
            Section {
                ModuleGroupView(store: store, agents: false)
                Text("通道开关仅影响 Mimi，不改变系统 Tailscale。修改 Tailscale 或局域网会重载 Mimi 服务，移动连接可能短暂中断。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Tailcat 实验 · 高级设置") {
                TextField("DERP Map HTTPS URL（留空使用默认值）", text: $derpMapURL)
                    .textFieldStyle(.roundedBorder)
                Button("保存中继配置") { Task { await store.configureTailcatDERPMap(derpMapURL) } }
                    .disabled(!store.canManageModules)
                Button("重置 Tailcat 配对…", role: .destructive) { confirmsTailcatReset = true }
                    .disabled(!store.canManageModules || !store.tailcatEnabled)
                if let error = store.tailcatError { Text(error).foregroundStyle(.red).font(.caption) }
                if let notice = store.tailcatNotice { Text(notice).font(.caption) }
            }
            feedback
        }.formStyle(.grouped)
    }

    private var fileAccess: some View {
        Form {
            Section("文件访问") {
                let presentation = FileAccessSettingsPresentation.make(owner: store.owner, photosAccess: store.photosAccess)
                LabeledContent("照片图库", value: presentation.photosStatus)
                if let action = presentation.photosAction {
                    Button(action.title) { Task { await store.requestPhotosAccess() } }
                }
                Text(presentation.photosCaption).font(.caption).foregroundStyle(.secondary)
                Button(FileAccessSettingsPresentation.fullDiskAccessActionTitle) { store.openFullDiskAccessSettings() }
                Text(presentation.fullDiskAccessCaption).font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).onAppear { store.refreshPhotosAccess() }
    }

    private var service: some View {
        Form {
            Section("当前服务") {
                LabeledContent("状态", value: store.lifecycle.title)
                LabeledContent("运行方式", value: ownerTitle)
                if let status = store.status {
                    LabeledContent("agentd 版本", value: status.serverVersion ?? status.version)
                    Text(status.endpoint).font(.caption.monospaced()).textSelection(.enabled)
                    LabeledContent("项目数", value: String(status.projects))
                }
                Button("刷新状态") { Task { await store.refreshModules() } }.disabled(store.isBusy)
                Button("重新启动 Mimi 服务") { Task { await store.restartService() } }
                    .disabled(store.isBusy || store.owner != .macApp)
                Button("诊断与日志…") { openWindow(id: AppWindow.diagnostics.rawValue) }
                if store.canRestoreHomebrew {
                    Button("停止 App 服务并恢复 Homebrew…", role: .destructive) { confirmsRestore = true }
                        .disabled(store.isBusy)
                }
            }
            feedback
        }.formStyle(.grouped)
    }

    @ViewBuilder private var feedback: some View {
        if let error = store.lastError {
            Section("需要处理") { Text(error).font(.callout).textSelection(.enabled) }
        }
        if let undo = store.moduleUndo {
            Section {
                HStack {
                    Text("已关闭 \(undo.module.title)")
                    Spacer()
                    Button("撤销") { Task { await store.undoModuleChange() } }.disabled(!store.canManageModules)
                }
            }
        }
        if store.owner != .macApp {
            Section { Text("先在主窗口接管 App 服务，才能修改模块设置。").foregroundStyle(.secondary) }
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

/// “文件访问”分组必须描述**正在处理文件请求的服务**的权限。
///
/// `PhotosAccessState` 读的是 Mimi Remote Mac 自己的照片授权，只有 App 托管 agentd（supervisor）
/// 时才会沿责任链作用于服务。Homebrew 运行的 agentd 没有 App 外壳，照片图库只能靠完全磁盘
/// 访问放行；这时展示 App 的“已允许”或给出“允许访问照片”都会误导用户。
struct FileAccessSettingsPresentation: Equatable {
    enum PhotosAction: Equatable {
        case requestPhotosAccess
        case openPhotosPrivacySettings

        var title: String {
            switch self {
            case .requestPhotosAccess: "允许访问照片…"
            case .openPhotosPrivacySettings: "打开照片隐私设置…"
            }
        }
    }

    static let fullDiskAccessActionTitle = "打开完全磁盘访问权限设置…"
    static let homebrewAgentdPath = "/opt/homebrew/opt/mimi-remote/bin/agentd"

    let photosStatus: String
    let photosAction: PhotosAction?
    let photosCaption: String
    let fullDiskAccessCaption: String

    static func make(owner: ServiceOwner, photosAccess: PhotosAccessState) -> Self {
        switch owner {
        case .homebrew:
            return Self(
                photosStatus: "由完全磁盘访问控制",
                photosAction: nil,
                photosCaption: "当前服务由 Homebrew 运行，Mimi Remote Mac 的照片权限不会作用于它。需要预览“照片”里的图片时，请在“完全磁盘访问”中添加 agentd。",
                fullDiskAccessCaption: "在列表中添加 \(homebrewAgentdPath)。桌面、文稿、下载和照片图库都由这项授权放行。"
            )
        case .macApp, .none:
            let action: PhotosAction? = switch photosAccess {
            case .notDetermined: .requestPhotosAccess
            case .denied, .restricted: .openPhotosPrivacySettings
            case .authorized, .limited: nil
            }
            return Self(
                photosStatus: photosAccess.title,
                photosAction: action,
                photosCaption: "在 Mac 上把“照片”里的图片拖进会话后，iPhone 或 iPad 预览这些图片需要该权限。Mimi 不会修改或上传照片。",
                fullDiskAccessCaption: "只有需要读取 Mail、Safari 等其他 App 的数据时，才需要在“完全磁盘访问”中添加 Mimi Remote Mac。桌面、文稿和下载会在首次访问时由系统单独询问。"
            )
        }
    }
}
