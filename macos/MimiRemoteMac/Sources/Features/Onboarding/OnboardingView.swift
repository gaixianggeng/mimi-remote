import SwiftUI
import UniformTypeIdentifiers

struct OnboardingView: View {
    /// 与 iOS 首次连接引导、README「Get started」第一步同一链接。
    static let codexSetupURL = URL(string: "https://learn.chatgpt.com/docs/codex/cli")!

    let store: HostStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var selectedRoot: URL?
    @State private var presentsFolderPicker = false

    init(store: HostStore) {
        self.store = store
        let suggested = FileManager.default.homeDirectoryForCurrentUser.appending(path: "code")
        _selectedRoot = State(initialValue: FileManager.default.fileExists(atPath: suggested.path) ? suggested : nil)
    }

    var body: some View {
        InfoCard("首次设置") {
            Text("选择放代码的文件夹，比如 ~/code。手机上会直接列出里面的项目，点一下就能打开。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Image(systemName: "folder")
                Text(selectedRoot?.path ?? "尚未选择文件夹")
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer()
                Button("选择…") { presentsFolderPicker = true }
            }

            // 真正的前提是这台 Mac 上有能用的 Codex；过去从下载到新建会话都没人提过（#554）。
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("还需要在这台 Mac 上安装并登录 Codex，命令行版或 ChatGPT 桌面版都可以。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link("如何安装", destination: Self.codexSetupURL)
            }
            .font(.callout)

            Button("完成设置并显示二维码") {
                guard let selectedRoot else { return }
                Task {
                    await store.completeSetup(workspaceRoot: selectedRoot)
                    // 设置成功后直接给二维码，不再让用户回菜单栏找「配对设备…」（#554）。
                    guard store.lastError == nil, store.pairing != nil else { return }
                    openWindow(id: AppWindow.pairing.rawValue)
                    dismissWindow(id: AppWindow.dashboard.rawValue)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedRoot == nil || store.isBusy)
        }
        .fileImporter(
            isPresented: $presentsFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result {
                selectedRoot = urls.first
            }
        }
    }
}
