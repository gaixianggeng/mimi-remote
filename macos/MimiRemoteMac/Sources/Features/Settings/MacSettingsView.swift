import SwiftUI

struct MacSettingsView: View {
    let store: HostStore
    let updates: AppUpdateStore
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

            TailcatRelaySettings(store: store)

            Section("文件访问") {
                let fileAccess = FileAccessSettingsPresentation.make(
                    owner: store.owner,
                    photosAccess: store.photosAccess
                )
                LabeledContent("照片图库", value: fileAccess.photosStatus)
                if let action = fileAccess.photosAction {
                    Button(action.title) {
                        Task { await store.requestPhotosAccess() }
                    }
                }
                Text(fileAccess.photosCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(FileAccessSettingsPresentation.fullDiskAccessActionTitle) {
                    store.openFullDiskAccessSettings()
                }
                Text(fileAccess.fullDiskAccessCaption)
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
        .frame(width: 560, height: 720)
        .task {
            await store.refreshIfNeeded()
            await store.refreshTailcatStatus()
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
