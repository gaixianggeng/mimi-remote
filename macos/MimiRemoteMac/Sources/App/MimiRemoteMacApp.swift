import SwiftUI

/// Mimi Remote Mac 只运行菜单栏 App；后台 Codex App Server 由 agentd 托管。
@main
enum MimiRemoteMacMain {
    static func main() {
        // 覆盖升级后，旧 LaunchAgent 可能仍带着该参数启动新二进制。
        // 这里只退出，绝不恢复已移除的共享 daemon，也不误开第二个菜单栏 App。
        if CommandLine.arguments.contains("--codex-daemon-supervisor") {
            return
        }
        MimiRemoteMacApp.main()
    }
}

struct MimiRemoteMacApp: App {
    @State private var store: HostStore

    init() {
#if DEBUG
        let usesSeedUI = ProcessInfo.processInfo.arguments.contains("--debug-seed-ui")
        // README 截图使用受控的演示数据，避免把本机地址、项目数量和账户额度带入公开仓库。
        let store = usesSeedUI ? HostStore.preview(.ready) : HostStore.live()
#else
        let store = HostStore.live()
#endif
        _store = State(initialValue: store)
#if DEBUG
        guard !usesSeedUI else { return }
#endif
        Task { @MainActor in
            await store.bootstrap()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(store: store)
        } label: {
            // 菜单栏使用稳定的品牌标记，服务状态交由弹窗内的语义图标表达。
            MimiMenuBarMark()
                .accessibilityLabel("Mimi Remote Mac：\(store.lifecycle.title)")
        }
        .menuBarExtraStyle(.window)

        Window("Mimi Remote Mac", id: AppWindow.dashboard.rawValue) {
            DashboardView(store: store)
        }
        .defaultSize(width: 560, height: 520)

        Window("配对设备", id: AppWindow.pairing.rawValue) {
            PairingView(store: store)
        }
        .defaultSize(width: 500, height: 740)

        Window("诊断与日志", id: AppWindow.diagnostics.rawValue) {
            DiagnosticsView(store: store)
        }
        .defaultSize(width: 720, height: 620)

        Window("实验功能", id: ExperimentMenuRouting.windowID) {
            ExperimentsView(store: store)
        }
        .defaultSize(width: 500, height: 680)

        Settings {
            MacSettingsView(store: store)
        }
    }
}

private struct MimiMenuBarMark: View {
    var body: some View {
        Image("MimiMenuBarIcon")
            .resizable()
            .renderingMode(.template)
            .interpolation(.high)
            .scaledToFit()
            // 只缩小可见字标，保留原标签占位，避免点击区域和菜单栏间距一起缩水。
            .frame(width: 22, height: 16)
            .frame(width: 25, height: 18)
    }
}

enum AppWindow: String {
    case dashboard
    case pairing
    case diagnostics
    case experiments
}
