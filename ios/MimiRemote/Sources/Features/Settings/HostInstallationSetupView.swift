import SwiftUI

enum HostInstallationPlatform: String, CaseIterable, Identifiable {
    case mac
    case windows

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mac:
            "Mac"
        case .windows:
            "Windows"
        }
    }

    var installTitle: String {
        switch self {
        case .mac:
            L10n.text("ui.install_mimi_remote_mac")
        case .windows:
            L10n.text("ui.install_mimi_remote_windows")
        }
    }

    var installationDetail: String {
        switch self {
        case .mac:
            L10n.text("ui.mac_installer_requirements_and_instructions")
        case .windows:
            L10n.text("ui.windows_installer_requirements_and_instructions")
        }
    }

    var shareTitle: String {
        switch self {
        case .mac:
            L10n.text("ui.send_download_link_to_mac")
        case .windows:
            L10n.text("ui.send_download_link_to_windows")
        }
    }

    var installerURL: URL {
        switch self {
        case .mac:
            AppExternalLinks.macInstaller
        case .windows:
            AppExternalLinks.windowsRelease
        }
    }

    var releaseURL: URL {
        switch self {
        case .mac:
            AppExternalLinks.macRelease
        case .windows:
            AppExternalLinks.windowsRelease
        }
    }
}

/// 安装说明放在添加电脑模块中，两处连接页面保持相同的展开方式。
/// 平台选择只改变远端安装入口；配对和凭据处理继续复用同一条安全链路。
struct HostInstallationSetupView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore
    @StateObject private var transientPreferences: SettingsTransientPreferences

    init(transientPreferences: SettingsTransientPreferences? = nil) {
        _transientPreferences = StateObject(
            wrappedValue: transientPreferences ?? SettingsTransientPreferences()
        )
    }

    /// 安装说明一律默认折叠：扫码才是主路径，需要时再展开。
    private var isExpanded: Binding<Bool> {
        Binding(
            get: { transientPreferences.hostInstallationExpansionOverride ?? false },
            set: { transientPreferences.hostInstallationExpansionOverride = $0 }
        )
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        // Form 会把 DisclosureGroup 的展开内容当作子行再缩进一级（约 20pt），和下方扫码按钮、
        // 其他入口的起始边对不齐。这里只让 DisclosureGroup 负责标题行、系统展开箭头和旁白的
        // 展开状态；内容作为同级行跟随同一个展开状态出现，与整个分组共用一条起始边。
        DisclosureGroup(isExpanded: isExpanded) {
            EmptyView()
        } label: {
            ConnectionRowLabel(title: L10n.text("ui.install_on_your_computer"), systemImage: "arrow.down.app")
                .accessibilityIdentifier("settings.hostInstaller.disclosure")
        }
        .disclosureGroupStyle(SettingsDisclosureGroupStyle())
        .settingsRow()
        .settingsGroupRowStyle()

        if isExpanded.wrappedValue {
            VStack(alignment: .leading, spacing: 16) {
                SettingsChoiceRow(
                    title: L10n.text("ui.computer_platform"),
                    systemImage: "desktopcomputer",
                    options: HostInstallationPlatform.allCases,
                    selection: $transientPreferences.hostInstallationPlatform
                )
                .accessibilityIdentifier("settings.hostInstaller.platform")

                VStack(alignment: .leading, spacing: 6) {
                    Text(transientPreferences.hostInstallationPlatform.installTitle)
                        .font(themeStore.uiFont(.body, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)

                    Text(transientPreferences.hostInstallationPlatform.installationDetail)
                        .font(themeStore.uiFont(.footnote))
                        .foregroundStyle(tokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.hostInstaller.installationDetail")

                Link(destination: transientPreferences.hostInstallationPlatform.releaseURL) {
                    HStack(spacing: SettingsLayoutMetrics.iconSpacing) {
                        // 品牌资源保持官方黑白原色，不跟随 App 的主题色染色。
                        Image("GitHubInvertocat")
                            .renderingMode(.original)
                            .resizable()
                            .scaledToFit()
                            .frame(width: SettingsLayoutMetrics.iconSlot, height: SettingsLayoutMetrics.iconSlot)
                            .accessibilityHidden(true)

                        Text(L10n.text("ui.view_releases_on_github"))
                            .font(themeStore.uiFont(.body))
                            .foregroundStyle(tokens.primaryText)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: SettingsLayoutMetrics.trailingAccessorySpacing)

                        // 外链标记与相邻行的展开、导航箭头同宽同色，落在同一列。
                        SettingsTrailingAccessory(systemImage: "arrow.up.right")
                    }
                    .settingsRow()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("ui.view_releases_on_github"))
                .accessibilityHint(L10n.text("ui.github_release_accessibility_hint"))
                .accessibilityIdentifier("settings.hostInstaller.githubRelease")

                // 不用 ShareLink：它在这一行里点了没有任何反应（#424，模拟器与真机都复现，
                // 原因未定位）。分享面板由连接页整页呈现，这里只登记请求。
                Button {
                    transientPreferences.hostInstallerShareRequest = HostInstallerShareRequest(
                        url: transientPreferences.hostInstallationPlatform.installerURL
                    )
                } label: {
                    ConnectionActionLabel(
                        title: transientPreferences.hostInstallationPlatform.shareTitle,
                        systemImage: "square.and.arrow.up"
                    )
                }
                .buttonStyle(.bordered)
                // tint 同时决定 bordered 按钮的底色和文字色。只给中性 tint 会让文字
                // 也变成次级灰，整枚按钮读起来像被禁用；底保持中性，文字单独回到正文色。
                .tint(tokens.secondaryText)
                .foregroundStyle(tokens.primaryText)
                .controlSize(.large)
                .accessibilityIdentifier("settings.hostInstaller.share")
                Text(L10n.text("ui.select_code_directory_then_computer_shows_qr"))
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(tokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 12)
            .settingsRow()
            .settingsGroupRowStyle()
            // 展开内容是标题行的延续，不用分隔线把两者切开。
            .listRowSeparator(.hidden, edges: .top)

            commandLineInstallation(tokens: tokens)
        }
    }

    /// 命令行安装是同一件事的高级做法，收在安装指引内部，不在添加流程里另起一个同级入口。
    private func commandLineInstallation(tokens: ThemeTokens) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("ui.first_time_installation"))
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.secondaryText)
                Text("brew install gaixianggeng/tap/mimi-remote")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                Text(L10n.text("ui.start_the_assistant_and_display_the_qr_code"))
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.secondaryText)
                Text("agentd up")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                Text(L10n.text("ui.run_agentd_pair_when_the_qr_code_expires"))
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(tokens.secondaryText)
            }
            .foregroundStyle(tokens.primaryText)
            // 展开内容与标题同在一行，底部要自己留出与下一行的距离。
            .padding(.top, 6)
            .padding(.bottom, 14)
        } label: {
            ConnectionRowLabel(
                title: L10n.text("ui.command_line_installation_advanced"),
                systemImage: "terminal"
            )
        }
        .disclosureGroupStyle(SettingsDisclosureGroupStyle())
        .settingsRow()
        .settingsGroupRowStyle()
        .accessibilityIdentifier("settings.hostInstaller.commandLine")
    }
}

struct HostInstallerShareRequest: Identifiable {
    let id = UUID()
    let url: URL
}

/// 连接页整页持有分享面板的 presenter；只观察这一个对象，登记请求时不会让整页重算。
/// 设备页和添加电脑页会同时存在于导航栈里，只有真正显示安装说明的那一页才能绑定请求。
struct HostInstallerSharePresenter: ViewModifier {
    @ObservedObject var preferences: SettingsTransientPreferences
    var isEnabled = true

    func body(content: Content) -> some View {
        content.sheet(item: shareRequestBinding) { request in
            HostInstallerActivityView(url: request.url)
        }
    }

    private var shareRequestBinding: Binding<HostInstallerShareRequest?> {
        Binding(
            get: { isEnabled ? preferences.hostInstallerShareRequest : nil },
            set: { request in
                guard isEnabled else { return }
                preferences.hostInstallerShareRequest = request
            }
        )
    }
}

/// 系统分享面板。与 ShareJourneyActivityView 相同的包装，只是分享的是安装包链接。
struct HostInstallerActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// 图标与文字作为一个整体居中，避免宽窗口中两者分散到按钮两端。
struct ConnectionActionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .accessibilityHidden(true)

            Text(title)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

/// 按容器宽度分配主辅操作，窄屏优先保证粘贴的触控区域，并让换行后的两个按钮等高。
struct ConnectionPrimaryActionsLayout: Layout {
    let layoutDirection: LayoutDirection
    private let spacing: CGFloat = 8

    private func widths(in width: CGFloat, minimumPasteWidth: CGFloat) -> (scan: CGFloat, paste: CGFloat) {
        let paste = max(minimumPasteWidth, (width - spacing) * 0.12)
        return (width - spacing - paste, paste)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let idealWidth = subviews.reduce(spacing) { $0 + $1.sizeThatFits(.unspecified).width }
        let proposedWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        // 大字体下系统按钮可能比 44pt 更宽，按实际最小宽度留位，避免背景越过卡片内边距。
        let minimumPasteWidth = max(44, subviews[1].sizeThatFits(.unspecified).width)
        let width = max(44 + spacing + minimumPasteWidth, proposedWidth ?? idealWidth)
        let sizes = widths(in: width, minimumPasteWidth: minimumPasteWidth)
        let scanHeight = subviews[0].sizeThatFits(.init(width: sizes.scan, height: nil)).height
        let pasteHeight = subviews[1].sizeThatFits(.init(width: sizes.paste, height: nil)).height
        return CGSize(width: width, height: max(44, scanHeight, pasteHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let minimumPasteWidth = max(44, subviews[1].sizeThatFits(.unspecified).width)
        let sizes = widths(in: bounds.width, minimumPasteWidth: minimumPasteWidth)
        let isRightToLeft = layoutDirection == .rightToLeft
        subviews[0].place(
            at: CGPoint(x: isRightToLeft ? bounds.maxX - sizes.scan : bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: .init(width: sizes.scan, height: bounds.height)
        )
        subviews[1].place(
            at: CGPoint(x: isRightToLeft ? bounds.minX : bounds.maxX - sizes.paste, y: bounds.minY),
            anchor: .topLeading,
            proposal: .init(width: sizes.paste, height: bounds.height)
        )
    }
}

/// 普通连接入口使用固定图标列，让标题与说明共享同一条起始边。
struct ConnectionRowLabel: View {
    let title: String
    var value: String? = nil
    let systemImage: String
    var valueTint: Color? = nil
    var titleTint: Color? = nil

    var body: some View {
        SettingsValueLabel(
            title: title,
            value: value,
            systemImage: systemImage,
            valueTint: valueTint,
            titleTint: titleTint
        )
    }
}

/// 线路行：设备首页与连接方式页共用同一个组件，展示上一次探测并原地刷新。
/// 与导航行同一套「标题左、值右」布局：放得下就一行 52pt，大字号或窄窗口才折成两行。
/// 刷新中只把 ↻ 换成 spinner，旧值保留不清空。
struct RouteStatusRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var themeStore: ThemeStore

    let value: String
    var isFailed = false
    var isBusy = false
    var isEnabled = true
    var refreshAccessibilityIdentifier = "settings.connection.refreshRoute"
    let onRefresh: () -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        // 整行就是「重新测一次」：刷新标记缩到与相邻行的导航箭头同宽、落在同一列，
        // 值文字因此与上下行右对齐（#563）。过去这里是一枚 44pt 的独立按钮，图标居中，
        // 值和图标都比箭头行往左缩了一大截。点击区域改为整行，比 44pt 圆钮更好点。
        Button(action: onRefresh) {
            HStack(spacing: SettingsLayoutMetrics.trailingAccessorySpacing) {
                ConnectionRowLabel(
                    title: L10n.text("ui.route_label"),
                    value: value,
                    systemImage: "antenna.radiowaves.left.and.right",
                    valueTint: isFailed ? tokens.warning : nil
                )

                SettingsTrailingAccessory(systemImage: "arrow.clockwise", isBusy: isBusy)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isBusy)
        .accessibilityHint(L10n.text("ui.refresh"))
        .accessibilityIdentifier(refreshAccessibilityIdentifier)
        .animation(reduceMotion ? nil : .default, value: isBusy)
    }
}

/// 线路相关文案只在这里拼：路径短标签、HTTP 耗时、探测时间，首页和连接方式页口径一致。
enum ConnectionRouteFormatting {
    static func timeText(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// 首页单行放得下的时间：当天写时刻，昨天写「昨天」，更早只写月/日。
    /// 「2026年9月24日 22:10」这种完整写法会把诊断行挤成两行，完整时间留给诊断页。
    static func compactTimeText(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) {
            return L10n.text("ui.yesterday")
        }
        return date.formatted(.dateTime.month(.defaultDigits).day())
    }

    /// 卡片里不写「直连（UDP 打洞）」这种解释性全称，解释留给诊断页。
    static func pathText(_ path: String, region: String?) -> String {
        switch path {
        case "direct":
            return L10n.text("ui.route_path_direct")
        case "peer-relay":
            return L10n.text("ui.tailscale_path_peer_relay")
        case "derp":
            return L10n.text("ui.tailscale_path_derp") + (region.map { " (\($0))" } ?? "")
        default:
            return L10n.text("ui.tailscale_path_unknown")
        }
    }

    static func httpText(_ millis: Int) -> String {
        L10n.format("ui.route_http_latency_value", String(millis))
    }

    static func latencyText(_ millis: Int) -> String {
        "\(millis) ms"
    }

    /// 设备首页只区分直连和中转：DERP 与 Peer Relay 的差别属于诊断细节，留给「连接方式」页。
    static func briefPathText(_ path: String) -> String {
        switch path {
        case "direct":
            return L10n.text("ui.route_path_direct")
        case "peer-relay", "derp":
            return L10n.text("ui.route_path_relay")
        default:
            return L10n.text("ui.tailscale_path_unknown")
        }
    }

    static func briefPathText(_ kind: TailscaleNetworkPathResponse.Kind?) -> String? {
        switch kind {
        case .direct:
            return L10n.text("ui.route_path_direct")
        case .peerRelay, .derp:
            return L10n.text("ui.route_path_relay")
        case .notTailscale, .unknown, .unavailable, nil:
            return nil
        }
    }

    /// 首页线路行必须放进一行，只答两件事：直连还是中转、多少毫秒。
    /// 路径通但 HTTP 失败仍要写出来，不能只靠着色（VoiceOver 读不到颜色）。
    static func briefSummary(_ diagnostic: TailcatPathDiagnostic) -> String {
        guard diagnostic.succeeded else {
            return L10n.text("ui.route_probe_failed")
        }
        var parts = [briefPathText(diagnostic.path)]
        if diagnostic.requestSucceeded == false {
            parts.append(L10n.text("ui.tailcat_request_failed"))
        } else if let millis = diagnostic.latencyMillis ?? diagnostic.requestLatencyMillis {
            parts.append(latencyText(millis))
        }
        return parts.joined(separator: " · ")
    }

    /// 回退线路没有 disco 延迟，毫秒数取 health 请求耗时；路径判断不出来时只给毫秒。
    static func briefSummary(_ probe: FallbackRouteProbe) -> String {
        guard probe.succeeded else {
            return L10n.text("ui.route_probe_failed")
        }
        var parts: [String] = []
        if let pathText = briefPathText(probe.pathKind) {
            parts.append(pathText)
        }
        if let millis = probe.httpMillis {
            parts.append(latencyText(millis))
        }
        guard !parts.isEmpty else {
            return L10n.text("ui.tailscale_path_unknown")
        }
        return parts.joined(separator: " · ")
    }

    /// 「连接方式」页的完整摘要：路径 · 延迟 · HTTP 耗时 · 时间。数字只代表探测那一刻。
    static func compactSummary(_ diagnostic: TailcatPathDiagnostic) -> String {
        var parts: [String] = []
        if diagnostic.succeeded {
            parts.append(pathText(diagnostic.path, region: diagnostic.derpRegionCode))
            if let latency = diagnostic.latencyMillis {
                parts.append("\(latency) ms")
            }
        } else {
            parts.append(L10n.text("ui.route_probe_failed"))
        }
        // 路径通但 HTTP 失败也是失败：写进文字，不能只靠着色（VoiceOver 读不到颜色）。
        if diagnostic.requestSucceeded == true, let httpMillis = diagnostic.requestLatencyMillis {
            parts.append(httpText(httpMillis))
        } else if diagnostic.requestSucceeded == false {
            parts.append(L10n.text("ui.tailcat_request_failed"))
        }
        parts.append(timeText(diagnostic.checkedAt))
        return parts.joined(separator: " · ")
    }

    static func isFailure(_ diagnostic: TailcatPathDiagnostic) -> Bool {
        !diagnostic.succeeded || diagnostic.requestSucceeded == false
    }
}

