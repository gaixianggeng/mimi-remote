import SwiftUI

enum HostSwitcherPresentation {
    case sidebar
    case toolbar
}

struct HostSwitcherMenu: View {
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var hostStatusStore: HostStatusStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let presentation: HostSwitcherPresentation
    let usesCondensedSidebarMetrics: Bool
    let manageConnections: () -> Void

    init(
        presentation: HostSwitcherPresentation,
        usesCondensedSidebarMetrics: Bool = false,
        manageConnections: @escaping () -> Void
    ) {
        self.presentation = presentation
        self.usesCondensedSidebarMetrics = usesCondensedSidebarMetrics
        self.manageConnections = manageConnections
    }

    @State private var failedProfileID: String?
    @State private var switchErrorMessage: String?

    var body: some View {
        styledMenu
            // 原生 Menu 没有 onOpen；同步手势只启动独立的一次性探测，菜单展示绝不等待网络。
            .simultaneousGesture(TapGesture().onEnded {
                hostStatusStore.refreshIfNeeded(appStore: appStore, sessionStore: sessionStore)
            })
            .task(id: platformRefreshTrigger) {
                guard Self.needsPlatformRefresh(appStore.connectionProfiles) else {
                    return
                }
                hostStatusStore.refreshIfNeeded(appStore: appStore, sessionStore: sessionStore)
            }
            .accessibilityIdentifier(accessibilityIdentifier)
            .alert(L10n.text("ui.switch_failed"), isPresented: errorPresentation) {
                if let failedProfileID {
                    Button(L10n.text("ui.retry")) {
                        switchToProfile(failedProfileID)
                    }
                }
                Button(L10n.text("ui.manage_connections")) {
                    manageConnections()
                }
                Button(L10n.text("ui.got_it"), role: .cancel) {}
            } message: {
                Text(switchErrorMessage ?? L10n.text("ui.please_try_again_later"))
            }
    }

    @ViewBuilder
    private var styledMenu: some View {
        switch presentation {
        case .sidebar:
            switcherMenu
        case .toolbar:
            switcherMenu
        }
    }

    private var switcherMenu: some View {
        Menu {
            ForEach(appStore.connectionProfiles) { profile in
                Button {
                    switchToProfile(profile.id)
                } label: {
                    Label(
                        profile.displayName,
                        systemImage: menuSystemImage(for: profile)
                    )
                }
                .disabled(
                    profile.id == appStore.activeConnectionProfileID ||
                        sessionStore.isConnectionSwitchInProgress
                )
            }

            if !appStore.connectionProfiles.isEmpty {
                Divider()
            }

            Button {
                hostStatusStore.refreshIfNeeded(appStore: appStore, sessionStore: sessionStore)
            } label: {
                Label(L10n.text("ui.check_host_status"), systemImage: "arrow.clockwise")
            }
            .disabled(sessionStore.isConnectionSwitchInProgress || sessionStore.isNetworkUnavailable)

            Button(action: manageConnections) {
                Label(L10n.text("ui.manage_connections"), systemImage: "gearshape")
            }
        } label: {
            switcherLabel
        }
    }

    @ViewBuilder
    private var switcherLabel: some View {
        let profileName = appStore.activeConnectionProfile?.displayName ?? L10n.text("ui.current_mac")
        let isSwitching = sessionStore.isConnectionSwitchInProgress

        switch presentation {
        case .sidebar:
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: usesCondensedSidebarMetrics ? 4 : 6) {
                    Text(profileName)
                        .font(
                            usesCondensedSidebarMetrics
                                ? .subheadline.weight(.semibold)
                                : .headline.weight(.semibold)
                        )
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    if appStore.connectionProfiles.count > 1 {
                        // 侧栏把平台降为状态行的小型辅助信息，避免与额度入口和主机名称争抢视觉。
                        HostPlatformGlyph(kind: currentHostIconKind, size: 11)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    if isSwitching {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Circle()
                            .fill(currentConnectionColor)
                            .frame(width: 6, height: 6)
                    }
                    Text(isSwitching ? L10n.text("ui.connecting") : currentConnectionText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: usesCondensedSidebarMetrics ? 136 : 150, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(switcherAccessibilityLabel(
                profileName: profileName,
                connectionText: isSwitching ? L10n.text("ui.connecting") : currentConnectionText
            )))
        case .toolbar:
            // 顶栏始终使用服务端真实平台增强辨识度；只有未知平台继续使用通用电脑，
            // 避免根据名称或地址猜测系统。
            ZStack(alignment: .bottomTrailing) {
                // 圆形按钮的触控范围保持不变，只放大品牌图形的光学占比。
                HostPlatformGlyph(kind: currentHostIconKind, size: 22)
                    .frame(width: 22, height: 22)

                if isSwitching {
                    ProgressView()
                        .controlSize(.mini)
                        .offset(x: 4, y: 4)
                } else {
                    Circle()
                        .fill(currentConnectionColor)
                        .frame(width: 6, height: 6)
                        // 徽标同步外移，避免放大后的品牌图形与连接状态挤在一起。
                        .offset(x: 4, y: 4)
                }
            }
            // 主机入口恢复原始主题主色；连接状态仍由右下角语义色圆点表达。
            .foregroundStyle(themeStore.tokens(for: colorScheme).primaryAction)
            // 磨砂圆交给调用方：放在导航栏里必须用不参与布局的
            // `workbenchToolbarChromeCircle`，放在自由浮层里才能用带真实尺寸的
            // `workbenchChromeCircle`。这里统一画会让导航栏那一路撑坏安全区。
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(switcherAccessibilityLabel(
                profileName: profileName,
                connectionText: isSwitching ? L10n.text("ui.connecting") : currentConnectionText
            )))
        }
    }

    private var currentHostIconKind: HostPlatformIconKind {
        Self.iconKind(for: appStore.activeConnectionProfile)
    }

    static func iconKind(for profile: ConnectionProfile?) -> HostPlatformIconKind {
        profile?.hostPlatform.iconKind ?? .genericComputer
    }

    static func needsPlatformRefresh(_ profiles: [ConnectionProfile]) -> Bool {
        profiles.contains(where: { $0.hostPlatform == .unknown })
    }

    private var platformRefreshTrigger: String {
        let profiles = appStore.connectionProfiles.map {
            "\($0.id):\($0.revision):\($0.hostPlatform.rawValue)"
        }.joined(separator: "|")
        return [
            profiles,
            String(sessionStore.isLoading),
            String(sessionStore.isNetworkUnavailable),
            String(sessionStore.isAppInBackground)
        ].joined(separator: ":")
    }

    private var accessibilityIdentifier: String {
        switch presentation {
        case .sidebar:
            return "hostSwitcher.sidebar.menu"
        case .toolbar:
            return "hostSwitcher.toolbar.menu"
        }
    }

    private func switcherAccessibilityLabel(
        profileName: String,
        connectionText: String
    ) -> String {
        var components = [profileName]
        if let platformName = appStore.activeConnectionProfile?.hostPlatform.displayName {
            components.append(platformName)
        }
        components.append(connectionText)
        return components.joined(separator: ", ")
    }

    private var errorPresentation: Binding<Bool> {
        Binding(
            get: { switchErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    switchErrorMessage = nil
                }
            }
        )
    }

    private var currentConnectionColor: Color {
        if sessionStore.isNetworkUnavailable {
            return .orange
        }
        switch appStore.connectionStatus {
        case .connected:
            return .green
        case .testing:
            return .orange
        case .failed:
            return .red
        case .idle:
            return .secondary
        }
    }

    private var currentConnectionText: String {
        if sessionStore.isNetworkUnavailable {
            return L10n.text("ui.offline")
        }
        switch appStore.connectionStatus {
        case .connected:
            return L10n.text("ui.connected")
        case .testing:
            return L10n.text("ui.connecting")
        case .failed:
            return L10n.text("ui.connection_failed")
        case .idle:
            return L10n.text("ui.connection_status")
        }
    }

    private func menuSystemImage(for profile: ConnectionProfile) -> String {
        if profile.id == appStore.activeConnectionProfileID {
            return "checkmark.circle.fill"
        }
        if sessionStore.connectionSwitchTargetProfileID == profile.id {
            return "clock"
        }
        switch hostStatusStore.status(for: profile).state {
        case .available:
            return "circle.fill"
        case .checking:
            return "clock"
        case .unavailable:
            return "wifi.slash"
        case .authenticationRequired:
            return "key.slash"
        case .identityMismatch:
            return "exclamationmark.shield"
        case .upgradeRequired:
            return "arrow.up.circle"
        case .unknown:
            return "circle"
        }
    }

    private func switchToProfile(_ profileID: String) {
        guard profileID != appStore.activeConnectionProfileID,
              !sessionStore.isConnectionSwitchInProgress else {
            return
        }
        hostStatusStore.cancel()
        switchErrorMessage = nil
        Task {
            do {
                _ = try await sessionStore.switchConnectionProfile(id: profileID)
                _ = await sessionStore.refreshAfterConnectionCommit(maxWait: 10)
                HostSwitchSignpost.event("session_index_visible")
                failedProfileID = nil
            } catch is CancellationError {
                // 退后台或用户取消时保留原 Mac，不弹失败。
            } catch {
                failedProfileID = profileID
                switchErrorMessage = error.localizedDescription
            }
        }
    }
}

/// 三个平台图标保持相同的视觉盒，连接状态由调用方独立表达。
/// 品牌平台使用自己的固定色，只有未知平台继续继承调用方的前景色。
struct HostPlatformGlyph: View {
    let kind: HostPlatformIconKind
    let size: CGFloat

    init(kind: HostPlatformIconKind, size: CGFloat = 18) {
        self.kind = kind
        self.size = size
    }

    @ViewBuilder
    private var glyph: some View {
        switch kind {
        case .apple:
            AppleRainbowMark(size: size * 8 / 9)
        case .windows11:
            Windows11Mark(spacing: size / 12)
                .frame(width: size * 5 / 6, height: size * 5 / 6)
        case .linuxTux:
            LinuxTuxMark(size: size)
        case .genericComputer:
            Image(systemName: "desktopcomputer")
                .font(.system(size: size * 8 / 9, weight: size < 14 ? .medium : .semibold))
                .symbolRenderingMode(.hierarchical)
        }
    }

    var body: some View {
        glyph
            .frame(width: size, height: size)
    }
}

/// 1977 彩虹苹果从上到下依次为绿、黄、橙、红、紫、蓝。
/// 直接用系统 Apple 轮廓做遮罩，既保留经典咬口，也无需维护另一份轮廓资源。
private struct AppleRainbowMark: View {
    @Environment(\.colorScheme) private var colorScheme

    let size: CGFloat

    private let colors: [Color] = [
        Color(red: 0.38, green: 0.73, blue: 0.27),
        Color(red: 0.99, green: 0.72, blue: 0.15),
        Color(red: 0.96, green: 0.51, blue: 0.12),
        Color(red: 0.88, green: 0.23, blue: 0.24),
        Color(red: 0.59, green: 0.24, blue: 0.59),
        Color(red: 0.00, green: 0.62, blue: 0.86)
    ]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(colors.indices, id: \.self) { index in
                colors[index]
            }
        }
        .frame(width: size, height: size)
        .mask {
            Image(systemName: "apple.logo")
                .resizable()
                .scaledToFit()
        }
        // 黄色条在浅色背景、黑色轮廓在深色背景都需要一层极轻的边缘分离。
        .shadow(
            color: colorScheme == .dark ? .white.opacity(0.24) : .black.opacity(0.18),
            radius: max(0.35, size / 36)
        )
    }
}

private struct Windows11Mark: View {
    let spacing: CGFloat

    var body: some View {
        VStack(spacing: spacing) {
            HStack(spacing: spacing) {
                tile
                tile
            }
            HStack(spacing: spacing) {
                tile
                tile
            }
        }
    }

    private var tile: some View {
        Rectangle()
            .fill(Color(red: 0.00, green: 0.47, blue: 0.83))
    }
}

/// 在现有可缩放 Tux 轮廓内叠加经典黑白、橙黄配色。
/// 彩色色块保持在透明负空间内，整体裁到统一视觉盒，避免缩小时污染状态圆点。
private struct LinuxTuxMark: View {
    @Environment(\.colorScheme) private var colorScheme

    let size: CGFloat

    private var width: CGFloat { size * 17 / 18 }
    private var outline: Color {
        colorScheme == .dark ? .white.opacity(0.34) : .black.opacity(0.12)
    }

    var body: some View {
        ZStack {
            // 原 SVG 的眼睛、肚皮和脚掌本身就是透明负空间，不能再把它当最终遮罩。
            // 先绘制黑色模板，再把经典配色填回这些区域，深色背景下才不会被透穿。
            Image("LinuxTux")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(Color(red: 0.08, green: 0.09, blue: 0.10))

            Ellipse()
                .fill(Color(red: 0.95, green: 0.95, blue: 0.92))
                .frame(width: width * 0.58, height: size * 0.55)
                .offset(y: size * 0.14)

            eye(xOffset: -width * 0.09)
            eye(xOffset: width * 0.09)

            TuxBeakShape()
                .fill(Color(red: 0.98, green: 0.66, blue: 0.08))
                .frame(width: width * 0.28, height: size * 0.14)
                .offset(y: -size * 0.13)

            foot(xOffset: -width * 0.20)
            foot(xOffset: width * 0.20)
        }
        .frame(width: width, height: size)
        .clipped()
        .shadow(color: outline, radius: max(0.45, size / 24))
    }

    private func eye(xOffset: CGFloat) -> some View {
        ZStack {
            Ellipse()
                .fill(Color.white)
                .frame(width: width * 0.19, height: size * 0.22)
            Circle()
                .fill(Color.black)
                .frame(width: max(1, width * 0.065), height: max(1, width * 0.065))
                .offset(y: size * 0.015)
        }
        .offset(x: xOffset, y: -size * 0.28)
    }

    private func foot(xOffset: CGFloat) -> some View {
        Ellipse()
            .fill(Color(red: 0.96, green: 0.57, blue: 0.06))
            .frame(width: width * 0.44, height: size * 0.18)
            .offset(x: xOffset, y: size * 0.43)
    }
}

private struct TuxBeakShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}
