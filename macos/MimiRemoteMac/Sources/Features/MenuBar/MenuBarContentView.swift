import AppKit
import SwiftUI

enum MenuBarLayout {
    static let contentInset: CGFloat = 12
    // 底部操作已经使用统一行高；收紧窗口底边留白，避免最后一行显得虚高。
    static let bottomInset: CGFloat = 6
    // 状态信息、运行时和操作区共用同一列网格，避免不同区块的图标与文字左右漂移。
    static let sectionInset: CGFloat = 3
    static let symbolColumnWidth: CGFloat = 16
    static let symbolTextSpacing: CGFloat = 8
    static let textColumnLeading = sectionInset + symbolColumnWidth + symbolTextSpacing
    // 模块、导航和底部操作共用固定高度，形成稳定节奏并保留完整点击区域。
    static let rowHeight: CGFloat = 44
    static let actionDividerOpacity: Double = 0.28
}

struct MenuBarContentView: View {
    let store: HostStore
    let updates: AppUpdateStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuStatusHeader(
                lifecycle: store.lifecycle,
                startingDetail: store.startingDetail,
                isRefreshing: store.isRefreshingStatus || store.isBusy,
                refresh: refreshStatus
            )

            AppUpdateNotice(updates: updates)

            Divider()
                .opacity(0.45)
                .padding(.top, 10)

            // MenuBarExtra 会把只有 maxHeight 的 ScrollView 压缩到接近 0。
            // 高频开关直接参与首屏固有尺寸计算，保证每次点开菜单栏都可见。
            VStack(alignment: .leading, spacing: 12) {
                ModuleControlsGroup(store: store, group: .agents)
                Divider().opacity(0.45)
                ModuleControlsGroup(store: store, group: .connections)
            }
            .padding(.vertical, 8)

            if let lastError = store.lastError {
                MenuStatusMessage(message: lastError)
                    .padding(.top, 8)
            }

            if needsPrimaryAction {
                Button {
                    performPrimaryAction()
                } label: {
                    Label(primaryActionTitle, systemImage: primaryActionSymbol)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(store.isBusy)
                .padding(.top, 10)
            }

            VStack(spacing: 0) {
                Divider()
                    .opacity(MenuBarLayout.actionDividerOpacity)

                MenuActionRow(title: "配对设备…", systemImage: "qrcode", isEnabled: !store.isBusy) {
                    // 空状态也可打开：说明是缺少助手、连接方式，还是服务未启动。
                    presentWindow(.pairing)
                }

                Divider()
                    .opacity(MenuBarLayout.actionDividerOpacity)
                    .padding(.leading, MenuBarLayout.textColumnLeading)

                MenuActionRow(
                    title: "运行诊断…",
                    systemImage: "waveform.path.ecg",
                    trailingText: diagnosticSummary
                ) {
                    presentWindow(.diagnostics)
                }

                Divider()
                    .opacity(MenuBarLayout.actionDividerOpacity)
                    .padding(.leading, MenuBarLayout.textColumnLeading)

                MenuActionRow(title: "设置…", systemImage: "gearshape") {
                    openSettings()
                    activateApplication()
                }

                Divider()
                    .opacity(MenuBarLayout.actionDividerOpacity)

                HStack(spacing: 6) {
                    MenuFooterActionButton(
                        title: "检查更新",
                        systemImage: "arrow.down.circle",
                        isEnabled: !updates.isChecking,
                        isWorking: updates.isChecking
                    ) {
                        openSettings()
                        activateApplication()
                        Task { await updates.check(manual: true) }
                    }

                    if store.owner == .macApp {
                        MenuFooterActionButton(
                            title: "重新启动",
                            systemImage: "arrow.clockwise",
                            isEnabled: !store.isBusy
                        ) {
                            presentRestartConfirmation()
                        }
                    }

                    MenuFooterActionButton(
                        title: "退出并停止",
                        systemImage: "power",
                        isEnabled: !store.isBusy,
                        role: .destructive
                    ) {
                        presentStopAndQuitConfirmation()
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, MenuBarLayout.contentInset)
        .padding(.top, MenuBarLayout.contentInset)
        .padding(.bottom, MenuBarLayout.bottomInset)
        .frame(width: 360)
        .background(MenuBarWindowPositionGuard())
        .animation(
            reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 1),
            value: store.lifecycle
        )
        .task {
            await store.refreshIfNeeded()
            await store.refreshTailcatStatus()
        }
    }

    private func refreshStatus() {
        Task {
            await store.refresh()
            await store.refreshTailcatStatus()
        }
    }

    private var diagnosticSummary: String? {
        guard let doctor = store.doctor else { return nil }
        let issueCount = doctor.checks.filter { !$0.ok }.count
        return issueCount == 0 ? nil : "\(issueCount) 项待处理"
    }

    private func performPrimaryAction() {
        switch store.lifecycle {
        case .notConfigured, .migrationRequired:
            presentWindow(.dashboard)
        case .degraded, .stopped, .failed:
            Task { await store.repairAndStartService() }
        case .loading, .starting, .ready:
            break
        }
    }

    private func presentWindow(_ window: AppWindow) {
        openWindow(id: window.rawValue)
        activateApplication()
    }

    private func activateApplication() {
        // 菜单栏 App 是 LSUIElement，SwiftUI 只创建窗口时不会自动把进程切到前台。
        // 等本轮菜单跟踪结束后再激活，避免系统仍把焦点留在刚关闭的 MenuBarExtra 上。
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    private func presentRestartConfirmation() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "重新启动 Mac 服务？"
            alert.informativeText = "移动连接会短暂断开，执行中的任务可能受影响。已有配置和配对不会删除。"
            alert.addButton(withTitle: "重新启动")
            alert.addButton(withTitle: "取消")
            NSApplication.shared.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            Task { await store.restartService() }
        }
    }

    private func presentStopAndQuitConfirmation() {
        // SwiftUI Alert 附着在 MenuBarExtra 的临时窗口上，窗口关闭时可能丢失后续异步动作。
        // 使用 AppKit 的应用级确认框，既符合 macOS 习惯，也能稳定地把结果交给全局 Store。
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "退出并停止 Mimi Remote Mac？"
            alert.informativeText = "这会立即中断 iPhone 和 iPad 的连接。下次打开 App 或重新登录 Mac 时会重新启动服务。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "退出并停止")
            alert.addButton(withTitle: "取消")
            alert.buttons.first?.hasDestructiveAction = true

            NSApplication.shared.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            store.requestStopServiceAndQuit()
        }
    }

    private var needsPrimaryAction: Bool {
        switch store.lifecycle {
        case .notConfigured, .migrationRequired, .degraded, .stopped, .failed:
            true
        case .loading, .starting, .ready:
            false
        }
    }

    private var primaryActionTitle: String {
        switch store.lifecycle {
        case .notConfigured:
            "完成首次设置…"
        case .migrationRequired:
            "迁移到 Mimi Remote Mac…"
        case .degraded, .stopped, .failed:
            "修复并启动服务"
        case .loading, .starting, .ready:
            ""
        }
    }

    private var primaryActionSymbol: String {
        switch store.lifecycle {
        case .notConfigured:
            "slider.horizontal.3"
        case .migrationRequired:
            "arrow.triangle.2.circlepath"
        case .degraded, .stopped, .failed:
            "wrench.and.screwdriver"
        case .loading, .starting, .ready:
            ""
        }
    }
}

private struct MenuStatusHeader: View {
    let lifecycle: HostLifecycleState
    var startingDetail: String? = nil
    let isRefreshing: Bool
    let refresh: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.14))

                if lifecycle == .loading || lifecycle == .starting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(statusColor)
                } else {
                    Image(systemName: lifecycle.symbolName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(statusColor)
                }
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            Button(action: refresh) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 16, height: 16)
                }
            }
            .buttonStyle(MenuIconButtonStyle())
            .disabled(isRefreshing)
            .help("刷新服务状态")
            .accessibilityLabel("刷新服务状态")
        }
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        switch lifecycle {
        case .loading: "正在检查 Mac 服务"
        case .notConfigured: "完成 Mac 端设置"
        case .migrationRequired: "Homebrew 服务正在运行"
        case .starting: "正在启动 Mimi Remote"
        case .ready: "Mac 服务运行中"
        case .degraded: "服务需要处理"
        case .stopped: "服务已停止"
        case .failed: "服务启动失败"
        }
    }

    private var subtitle: String {
        switch lifecycle {
        case .loading: "正在读取服务和连接状态。"
        case .notConfigured: "选择代码目录后即可配对移动设备。"
        case .migrationRequired: "可安全迁移，现有配置和配对都会保留。"
        case .starting: startingDetail ?? "移动设备连接会在服务就绪后自动恢复。"
        case .ready: "管理 AI 编程助手与移动连接。"
        case .degraded(let message), .failed(let message): message
        case .stopped: "打开 App 或重新登录后可以再次启动。"
        }
    }

    private var statusColor: Color {
        switch lifecycle {
        case .ready: .mimiPrimary
        case .loading, .starting: .blue
        case .notConfigured, .migrationRequired, .degraded: .orange
        case .stopped: .secondary
        case .failed: .red
        }
    }
}

private struct MenuStatusMessage: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.primary)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityLabel("注意：\(message)")
    }
}

private struct MenuActionRow: View {
    let title: String
    let systemImage: String
    var isEnabled = true
    var role: ButtonRole?
    var showsDisclosure = true
    var isWorking = false
    var trailingText: String?
    var accessibilityLabel: String?
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: MenuBarLayout.symbolTextSpacing) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(symbolColor)
                    .frame(width: MenuBarLayout.symbolColumnWidth)
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(labelColor)
                Spacer(minLength: 0)
                if let trailingText {
                    Text(trailingText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                } else if showsDisclosure {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, MenuBarLayout.sectionInset)
            .frame(
                maxWidth: .infinity,
                minHeight: MenuBarLayout.rowHeight,
                maxHeight: MenuBarLayout.rowHeight,
                alignment: .leading
            )
            .background(
                hoverBackgroundColor,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuPressButtonStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityLabel(accessibilityLabel ?? title)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }

    private var labelColor: Color {
        // 危险语义由电源图标与确认弹窗承接，文字保持普通层级，避免整行高饱和。
        .primary
    }

    private var symbolColor: Color {
        // 保留危险操作语义，但减少高饱和红色在菜单底部形成“主按钮”的错觉。
        role == .destructive ? Color(nsColor: .systemRed).opacity(0.62) : .secondary
    }

    private var hoverBackgroundColor: Color {
        guard isHovered else { return .clear }
        if role == .destructive {
            return Color(nsColor: .systemRed).opacity(0.03)
        }
        return Color.primary.opacity(0.055)
    }
}

private struct MenuPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(
                reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 1),
                value: configuration.isPressed
            )
    }
}

private struct MenuFooterActionButton: View {
    let title: String
    let systemImage: String
    var isEnabled = true
    var isWorking = false
    var role: ButtonRole?
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 5) {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 13, height: 13)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(symbolColor)
                        .frame(width: 13)
                }
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(
                maxWidth: .infinity,
                minHeight: MenuBarLayout.rowHeight,
                maxHeight: MenuBarLayout.rowHeight
            )
            .background(
                Color.primary.opacity(isHovered ? 0.08 : 0.045),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuPressButtonStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityLabel(title)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }

    private var symbolColor: Color {
        role == .destructive ? Color(nsColor: .systemRed).opacity(0.7) : .secondary
    }
}

private struct MenuIconButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(7)
            .background(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.055), in: Circle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(
                reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 1),
                value: configuration.isPressed
            )
    }
}

enum MenuBarWindowPlacement {
    static func correctedOriginY(
        windowFrame: CGRect,
        screenFrame: CGRect,
        menuBarHeight: CGFloat
    ) -> CGFloat {
        let highestAllowedOrigin = screenFrame.maxY - max(0, menuBarHeight) - windowFrame.height
        return min(windowFrame.minY, highestAllowedOrigin)
    }
}

private struct MenuBarWindowPositionGuard: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        MenuBarWindowProbeView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MenuBarWindowProbeView)?.scheduleAdjustment()
    }
}

private final class MenuBarWindowProbeView: NSView {
    private var adjustmentScheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleAdjustment()
    }

    override func layout() {
        super.layout()
        scheduleAdjustment()
    }

    func scheduleAdjustment() {
        guard !adjustmentScheduled else { return }
        adjustmentScheduled = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.adjustmentScheduled = false
            self.keepWindowBelowMenuBar()
        }
    }

    private func keepWindowBelowMenuBar() {
        guard let window, let screen = window.screen else { return }

        let currentFrame = window.frame
        let correctedY = MenuBarWindowPlacement.correctedOriginY(
            windowFrame: currentFrame,
            screenFrame: screen.frame,
            menuBarHeight: inferredMenuBarHeight(for: screen)
        )
        guard correctedY < currentFrame.minY - 0.5 else { return }

        // 全屏空间会把隐藏状态栏的锚点放到屏幕顶端；只修正垂直越界，保留系统计算的水平锚点。
        var correctedFrame = currentFrame
        correctedFrame.origin.y = correctedY
        window.setFrame(correctedFrame, display: true, animate: false)
    }

    private func inferredMenuBarHeight(for screen: NSScreen) -> CGFloat {
        let targetInset = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        let visibleMenuBarInset = NSScreen.screens
            .map { max(0, $0.frame.maxY - $0.visibleFrame.maxY) }
            .max() ?? 0

        return max(NSStatusBar.system.thickness, max(targetInset, visibleMenuBarInset))
    }
}

#if DEBUG
    #Preview("菜单栏 · 等待迁移") {
        MenuBarContentView(store: .preview(.migrationRequired), updates: AppUpdateStore())
    }

    #Preview("菜单栏 · 服务可用") {
        MenuBarContentView(store: .preview(.ready), updates: AppUpdateStore())
    }
#endif
