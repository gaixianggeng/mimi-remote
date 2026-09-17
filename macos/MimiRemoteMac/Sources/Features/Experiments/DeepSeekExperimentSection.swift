import SwiftUI

struct DeepSeekExperimentSection: View {
    let store: HostStore
    @State private var startupURL = ""

    var body: some View {
        Section("DeepSeek Harness") {
            LabeledContent("运行状态") {
                HStack(spacing: 6) {
                    if store.isUpdatingDeepSeek {
                        ProgressView().controlSize(.small)
                    }
                    Text(store.deepSeekStatusTitle)
                }
            }

            if let baseURL = store.deepSeekConfiguration?.baseURL, !baseURL.isEmpty {
                LabeledContent("服务地址", value: baseURL)
            }

            Text(store.deepSeekStatusDetail)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                if store.deepSeekEnabled {
                    Button("关闭通道") {
                        Task { await store.configureDeepSeek(.disabled) }
                    }
                } else if store.deepSeekConfiguration?.discovered == true {
                    Button("连接已发现的服务") {
                        Task { await store.configureDeepSeek(.connect) }
                    }
                }
                Button("重新检测") {
                    Task { await store.configureDeepSeek(.refresh) }
                }
            }
            .disabled(!store.canChangeDeepSeek || store.isUpdatingDeepSeek)

            DisclosureGroup("手动连接") {
                SecureField("Harness 启动链接", text: $startupURL,
                            prompt: Text("粘贴 dsh web 输出的完整链接"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("deepseek.startupURL")
                Button("验证并连接") {
                    let link = startupURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    startupURL = ""
                    Task { await store.configureDeepSeek(.connect, startupURL: link) }
                }
                .disabled(!store.canChangeDeepSeek || store.isUpdatingDeepSeek || startupURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("适用于终端启动或未被自动发现的服务。链接含访问凭据，不会显示在服务地址中。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("自动检测当前用户的 Harness 后台服务。连接时验证凭据并保存到本机；不会安装、启动或停止 Harness。加载通道会重启 agentd，现有连接会短暂重连。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { await store.inspectDeepSeek() }
    }
}
