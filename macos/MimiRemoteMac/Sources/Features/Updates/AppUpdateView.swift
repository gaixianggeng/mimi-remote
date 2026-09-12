import SwiftUI

struct AppUpdateView: View {
    let updates: AppUpdateStore

    var body: some View {
        LabeledContent("当前 App 版本", value: updates.currentVersion)
        if let release = updates.availableRelease {
            Label("新版本 \(release.version) 已发布", systemImage: "arrow.down.circle")
            HStack {
                Link("下载 Mac 更新", destination: release.downloadURL)
                Link("查看更新说明", destination: release.releaseURL)
            }
            Text("下载后退出 Mimi Remote Mac，在 Finder 中把 DMG 里的 App 拖入「应用程序」并替换，再从「应用程序」打开。配置和配对数据会保留。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Button(updates.isChecking ? "正在检查…" : "检查更新") {
            Task { await updates.check(manual: true) }
        }
        .disabled(updates.isChecking)
        if let error = updates.errorMessage {
            Text(error)
                .foregroundStyle(.secondary)
            Link("打开发布页面", destination: URL(string: "https://github.com/gaixianggeng/mimi-remote/releases/latest")!)
        } else if let message = updates.statusMessage {
            Text(message)
                .foregroundStyle(.secondary)
        }
        Text("启动时自动检查，运行期间每 24 小时检查一次。")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct AppUpdateNotice: View {
    let updates: AppUpdateStore

    var body: some View {
        if updates.showsUpdateNotice, let release = updates.availableRelease {
            VStack(alignment: .leading, spacing: 8) {
                Label("新版本 \(release.version) 已发布", systemImage: "arrow.down.circle")
                    .font(.headline)
                HStack {
                    Link("下载 Mac 更新", destination: release.downloadURL)
                    Spacer()
                    Button("稍后") { updates.deferUpdate() }
                }
                Text("下载后退出 App，在 Finder 中拖入「应用程序」并替换，再从「应用程序」打开。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 10)
            Divider()
        }
    }
}
