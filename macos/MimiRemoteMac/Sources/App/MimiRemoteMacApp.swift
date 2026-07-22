import SwiftUI

@main
struct MimiRemoteMacApp: App {
    @State private var store: HostStore

    init() {
        let store = HostStore.live()
        _store = State(initialValue: store)
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

        Window("配对 iPhone 或 iPad", id: AppWindow.pairing.rawValue) {
            PairingView(store: store)
        }
        .defaultSize(width: 460, height: 580)

        Window("诊断与日志", id: AppWindow.diagnostics.rawValue) {
            DiagnosticsView(store: store)
        }
        .defaultSize(width: 720, height: 620)

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
            // 粗笔画字标按视觉重量缩小一档，与相邻菜单栏图标保持平衡。
            .frame(width: 25, height: 18)
    }
}

enum AppWindow: String {
    case dashboard
    case pairing
    case diagnostics
}
