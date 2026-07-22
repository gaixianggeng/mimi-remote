import SwiftUI
import UniformTypeIdentifiers

struct OnboardingView: View {
    let store: HostStore
    @State private var selectedRoot: URL?
    @State private var presentsFolderPicker = false

    init(store: HostStore) {
        self.store = store
        let suggested = FileManager.default.homeDirectoryForCurrentUser.appending(path: "code")
        _selectedRoot = State(initialValue: FileManager.default.fileExists(atPath: suggested.path) ? suggested : nil)
    }

    var body: some View {
        InfoCard("首次设置") {
            Text("选择允许 Mimi Remote 发现和打开项目的代码根目录。第一版不会自动授权整个 Home。")
                .foregroundStyle(.secondary)

            HStack {
                Image(systemName: "folder")
                Text(selectedRoot?.path ?? "尚未选择目录")
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer()
                Button("选择…") { presentsFolderPicker = true }
            }

            Button("配置并启动") {
                guard let selectedRoot else { return }
                Task { await store.completeSetup(workspaceRoot: selectedRoot) }
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
