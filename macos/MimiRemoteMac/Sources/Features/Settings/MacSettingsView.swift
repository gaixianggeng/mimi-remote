import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MacSettingsView: View {
    let store: HostStore
    let updates: AppUpdateStore
    @Environment(\.openWindow) private var openWindow
    @State private var confirmsRestore = false
    @State private var workspaceScopeStore: WorkspaceScopeStore?
    @State private var isChoosingBrowseScope = false

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section("软件更新") {
                    AppUpdateView(updates: updates)
                }

                // 明确 `open_settings(assistants)` 落点：在设置页可直接管理 4 个 AI 编程助手。
                Section("AI 编程助手") {
                    if MenuBarPresentation.showsUnconfiguredGuideCard(
                        lifecycle: store.lifecycle,
                        isOnboardingInProgress: store.isOnboardingInProgress,
                        hasConfiguration: store.hasConfiguration()
                    ) {
                        Text("完成首次设置后，即可在此统一启用、关闭或排查 Codex、Claude Code、Antigravity 与 DeepSeek。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(MenuBarPresentation.unconfiguredGuideButtonTitle(isOnboardingInProgress: store.isOnboardingInProgress)) {
                            openWindow(id: AppWindow.dashboard.rawValue)
                            NSApplication.shared.activate(ignoringOtherApps: true)
                        }
                    } else {
                        ModuleControlsGroup(store: store, group: .agents)
                    }
                }
                .id(MacSettingsSection.assistants)

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
                    .id(MacSettingsSection.connections)

                Section("代码目录与浏览范围") {
                    if let scope = workspaceScopeStore {
                        LabeledContent("代码目录", value: scope.scanRoot?.path ?? "未读取")
                        LabeledContent("手机可浏览范围", value: scope.browseRoot?.path ?? "未读取")
                        Text("默认按最小权限仅授权手机访问所选代码目录。如需让手机浏览更大目录树，可在此查看完整授权范围并显式确认；取消不会影响已有配对。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 10) {
                            Button("扩大代码浏览范围（可选）…") {
                                isChoosingBrowseScope = true
                            }
                            .disabled(!scope.canWidenBrowseScope)

                            Button("刷新目录范围") {
                                Task { await scope.refresh() }
                            }
                            .disabled(scope.isLoading || scope.isApplying)
                        }

                        if let statusMessage = scope.statusMessage {
                            Text(statusMessage)
                                .font(.caption)
                                .foregroundStyle(Color.mimiPrimary)
                        }
                        if let errorMessage = scope.errorMessage {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    } else {
                        ProgressView("正在读取当前代码目录范围…")
                            .controlSize(.small)
                    }
                }

                Section("文件访问与本地网络权限") {
                    let fileAccess = FileAccessSettingsPresentation.make(
                        owner: store.owner,
                        photosAccess: store.photosAccess
                    )
                    LabeledContent("本地网络", value: "局域网配对按需授权")
                    Button(FileAccessSettingsPresentation.localNetworkActionTitle) {
                        store.openLocalNetworkSettings()
                    }
                    Text(fileAccess.localNetworkCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

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
                .id(MacSettingsSection.fileAccess)
                .onAppear {
                    store.refreshPermissionsOnReturn()
                }

                Section("隐私") {
                    Text("Mimi Remote Mac 不上传日志、代码、Token 或使用数据。长期 Token 只保存在 agentd 的私有配置中，App 只处理短期配对票据。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scenePadding()
            .frame(width: 560, height: 740)
            .task {
                if workspaceScopeStore == nil {
                    workspaceScopeStore = WorkspaceScopeStore(dependencies: .live(hostStore: store))
                }
                await store.refreshIfNeeded()
                await store.refreshTailcatStatus()
                await workspaceScopeStore?.refresh()
                scrollToRequestedSectionIfNeeded(using: proxy)
            }
            .onChange(of: store.requestedSettingsSection) { _, _ in
                scrollToRequestedSectionIfNeeded(using: proxy)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                // 从系统设置返回时自动做被动权限与目录范围刷新，绝不主动启动服务。
                store.refreshPermissionsOnReturn()
                Task { await workspaceScopeStore?.refresh() }
            }
            .fileImporter(
                isPresented: $isChoosingBrowseScope,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                guard let url = try? result.get().first else { return }
                workspaceScopeStore?.prepareWidenPreview(proposedBrowseRoot: url)
            }
            .sheet(
                item: Binding(
                    get: { workspaceScopeStore?.pendingPreview.map(IdentifiedBrowseScopePreview.init) },
                    set: { if $0 == nil { workspaceScopeStore?.cancelWidenPreview() } }
                )
            ) { item in
                WidenBrowseScopeConfirmationSheet(
                    preview: item.preview,
                    isApplying: workspaceScopeStore?.isApplying ?? false,
                    onCancel: { workspaceScopeStore?.cancelWidenPreview() },
                    onConfirm: { Task { await workspaceScopeStore?.confirmWidenBrowseScope() } }
                )
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

    private func scrollToRequestedSectionIfNeeded(using proxy: ScrollViewProxy) {
        guard let section = store.requestedSettingsSection else { return }
        DispatchQueue.main.async {
            withAnimation {
                proxy.scrollTo(section, anchor: .top)
            }
            store.requestedSettingsSection = nil
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

private struct IdentifiedBrowseScopePreview: Identifiable {
    let preview: WorkspaceBrowseScopePreview
    var id: String { preview.proposedBrowseRoot.path }
}

private struct WidenBrowseScopeConfirmationSheet: View {
    let preview: WorkspaceBrowseScopePreview
    let isApplying: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("确认扩大手机代码浏览范围？")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(preview.summaryLines, id: \.self) { line in
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(line.hasPrefix("注意：") ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                    .disabled(isApplying)
                Button(isApplying ? "正在应用…" : "确认扩大范围", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(isApplying)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

/// “文件访问与本地网络权限”分组必须描述**正在处理文件与网络请求的服务**的权限。
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

    static let localNetworkActionTitle = "打开本地网络权限设置…"
    static let fullDiskAccessActionTitle = "打开完全磁盘访问权限设置…"
    static let homebrewAgentdPath = "/opt/homebrew/opt/mimi-remote/bin/agentd"

    let photosStatus: String
    let photosAction: PhotosAction?
    let photosCaption: String
    let fullDiskAccessCaption: String
    let localNetworkCaption: String

    static func make(owner: ServiceOwner, photosAccess: PhotosAccessState) -> Self {
        let localNetworkCaption: String
        switch owner {
        case .homebrew:
            localNetworkCaption = "仅在使用“同一局域网”连接手机时需要；如果局域网连接被拒，请在“隐私与安全性 → 本地网络”中检查允许状态。切换回此窗口时会自动刷新权限状态。Tailscale 与内置连接不受影响。"
        case .macApp, .none:
            localNetworkCaption = "仅在使用“同一局域网”连接手机时需要。在“隐私与安全性 → 本地网络”中允许 Mimi Remote Mac 后，返回本页面会自动刷新状态；Tailscale 与内置连接不受影响。"
        }

        switch owner {
        case .homebrew:
            return Self(
                photosStatus: "由完全磁盘访问控制",
                photosAction: nil,
                photosCaption: "当前服务由 Homebrew 运行，Mimi Remote Mac 的照片权限不会作用于它。需要预览“照片”里的图片时，请在“完全磁盘访问”中添加 agentd。",
                fullDiskAccessCaption: "在列表中添加 \(homebrewAgentdPath)。桌面、文稿、下载和照片图库都由这项授权放行。",
                localNetworkCaption: localNetworkCaption
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
                fullDiskAccessCaption: "只有需要读取 Mail、Safari 等其他 App 的数据时，才需要在“完全磁盘访问”中添加 Mimi Remote Mac。桌面、文稿和下载会在首次访问时由系统单独询问。",
                localNetworkCaption: localNetworkCaption
            )
        }
    }
}
