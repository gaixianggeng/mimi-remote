import SwiftUI
import UIKit

// 个人页独立观察其实际依赖，避免 RootView 因连接状态细节整体重建。
struct ProfileRootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        ZStack {
            tokens.background.ignoresSafeArea()
            if horizontalSizeClass == .compact {
                NavigationStack {
                    profileContent(tokens: tokens)
                        .navigationTitle(L10n.text("ui.mine"))
                        .navigationBarTitleDisplayMode(.inline)
                }
                .themedWorkbenchNavigationChrome(tokens: tokens, colorScheme: themeStore.resolvedColorScheme(for: colorScheme))
            } else {
                profileContent(tokens: tokens)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(tokens.accent)
    }

    private func profileContent(tokens: ThemeTokens) -> some View {
        let isCompact = horizontalSizeClass == .compact

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if isCompact {
                    Text(L10n.text("ui.manage_mac_connections_models_and_tool_capabilities"))
                        .font(themeStore.uiFont(.callout, weight: .medium))
                        .foregroundStyle(tokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    WorkbenchPageHeader(
                        title: L10n.text("ui.mine"),
                        subtitle: L10n.text("ui.manage_mac_connections_models_and_tool_capabilities"),
                        tokens: tokens
                    )
                }

                MacConnectionPanel()
                CodexUsagePanel()

                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.text("ui.models_and_capabilities"))
                        .font(themeStore.uiFont(.headline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                    ProfileInfoRow(
                        systemImage: "sparkles",
                        title: "Codex",
                        value: L10n.text("ui.used_by_default"),
                        detail: L10n.text("ui.handle_session_tasks_by_default"),
                        tone: tokens.accent
                    )
                    ProfileInfoRow(
                        systemImage: "flask",
                        title: "Claude",
                        value: sessionStore.hasClaudeRuntimeChannel ? L10n.text("ui.found") : L10n.text("ui.configurable"),
                        detail: L10n.text("ui.can_be_used_for_session_tasks_after_configuration"),
                        tone: sessionStore.hasClaudeRuntimeChannel ? tokens.success : tokens.secondaryText
                    )
                    ProfileInfoRow(
                        systemImage: "cpu",
                        title: L10n.text("ui.model"),
                        value: modelSummary,
                        detail: L10n.text("ui.choose_the_right_model_for_a_new_task"),
                        tone: tokens.accent
                    )
                    ProfileInfoRow(
                        systemImage: "wand.and.stars",
                        title: "Skills / MCP",
                        value: L10n.text("ui.tool_ability"),
                        detail: L10n.text("ui.view_native_tools_and_extension_configurations"),
                        tone: tokens.accent
                    )
                }
            }
            .padding(.horizontal, isCompact ? WorkbenchPageLayout.compactPadding : WorkbenchPageLayout.regularPadding)
            .padding(.top, isCompact ? WorkbenchPageLayout.compactPadding : WorkbenchPageLayout.regularPadding)
            .padding(.bottom, isCompact ? WorkbenchPageLayout.compactBottomPadding : WorkbenchPageLayout.regularPadding)
            .frame(maxWidth: WorkbenchPageLayout.maxContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(tokens.background.ignoresSafeArea())
    }

    private var modelSummary: String {
        let count = sessionStore.appServerModelOptions.count
        return count == 0 ? L10n.text("ui.default_model") : L10n.plural("ui.models_count", count: count)
    }
}

struct CodexUsagePanel: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var isRefreshingUsage = false

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let display = sessionStore.accountCodexUsageWindowsDisplay

        VStack(alignment: .leading, spacing: 16) {
            header(display: display, tokens: tokens)

            VStack(alignment: .leading, spacing: 12) {
                if display.windows.isEmpty {
                    Text(L10n.text("ui.after_refreshing_the_account_window_currently_returned_by"))
                        .font(themeStore.uiFont(.footnote))
                        .foregroundStyle(tokens.secondaryText)
                } else {
                    ForEach(Array(display.windows.enumerated()), id: \.element.id) { index, window in
                        if index > 0 {
                            Divider()
                                .overlay(tokens.border.opacity(0.72))
                        }
                        usageWindowRow(window, tokens: tokens)
                    }
                }
            }

            footer(display: display, tokens: tokens)
        }
        .padding(16)
        .background(tokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tokens.border, lineWidth: 1)
        }
    }

    private func header(display: CodexUsageWindowsDisplay, tokens: ThemeTokens) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tokens.accent.opacity(0.12))
                // 19 不在档位表里，就近并入 title3（20）；14 同理并入 subheadline（15）。
                Image(systemName: "speedometer")
                    .font(themeStore.uiFont(.title3, weight: .semibold))
                    .foregroundStyle(tokens.accent)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.format("ui.value_dosage", display.displayName))
                    .font(themeStore.uiFont(.headline, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                    .lineLimit(1)
                Text(display.hasLiveData ? L10n.format("ui.codex_currently_returns_value", display.windowSummaryText) : L10n.text("ui.click_refresh_to_read_codex_account_limits"))
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(tokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            refreshButton(tokens: tokens)
        }
    }

    private func usageWindowRow(_ window: CodexUsageWindowDisplay, tokens: ThemeTokens) -> some View {
        let tint = windowTint(window, tokens: tokens)
        let progress = window.progress ?? 0

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: window.systemImage)
                        .font(themeStore.uiFont(.footnote, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 18)
                    Text(window.label)
                        .font(themeStore.uiFont(.headline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                        .monospacedDigit()
                    Text(window.title)
                        .font(themeStore.uiFont(.footnote, weight: .medium))
                        .foregroundStyle(tokens.secondaryText)
                }
                .lineLimit(1)

                Spacer(minLength: 8)

                Text(window.primaryText)
                    .font(themeStore.uiFont(.callout, weight: .semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .monospacedDigit()
            }

            ProgressView(value: progress)
                .tint(tint)
                .opacity(window.progress == nil ? 0.34 : 1)
                .accessibilityLabel(L10n.format("ui.value_dosage_ffbd1847", window.accessibilityName))
                .accessibilityValue(window.primaryText)

            Text(window.resetText)
                .font(themeStore.uiFont(.footnote))
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.86)
        }
    }

    private func footer(display: CodexUsageWindowsDisplay, tokens: ThemeTokens) -> some View {
        HStack(spacing: 8) {
            Image(systemName: display.hasLiveData ? "checkmark.seal" : "info.circle")
                .font(themeStore.uiFont(.footnote, weight: .semibold))
                .foregroundStyle(display.hasLiveData ? tokens.success : tokens.secondaryText)
            Text(display.creditText)
                .font(themeStore.uiFont(.footnote, weight: .medium))
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.86)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func refreshButton(tokens: ThemeTokens) -> some View {
        let isWorking = isRefreshingUsage || sessionStore.isLoading

        Button {
            Task { await refreshUsage() }
        } label: {
            Group {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tokens.secondaryText)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(themeStore.uiFont(.subheadline, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                }
            }
            .frame(width: 34, height: 34)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tokens.secondaryText)
        .background(tokens.surface.opacity(0.72), in: Circle())
        .overlay {
            Circle()
                .stroke(tokens.border.opacity(0.72), lineWidth: 1)
        }
        .disabled(isWorking)
        .accessibilityLabel(L10n.text("ui.refresh_codex_usage_c0f2c6f0"))
    }

    private func refreshUsage() async {
        guard !isRefreshingUsage else {
            return
        }
        isRefreshingUsage = true
        defer { isRefreshingUsage = false }
        await sessionStore.refreshCodexUsage()
    }

    private func windowTint(_ window: CodexUsageWindowDisplay, tokens: ThemeTokens) -> Color {
        if window.isExhausted || window.isNearLimit {
            return tokens.warning
        }
        if window.durationMinutes != nil {
            return window.isDayScaleWindow ? tokens.success : tokens.accent
        }
        return window.kind == .secondary ? tokens.success : tokens.accent
    }
}

struct MacConnectionPanel: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var endpoint = ""
    @State private var token = ""
    @State private var didLoadInitialConnection = false
    @State private var isSavingConnection = false
    @State private var isShowingQRCodeScanner = false
    @State private var isShowingManualFields = false
    @State private var pendingRemovalConfirmation: ConnectionCredentialRemovalConfirmation?
    @State private var localError: String?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 16) {
            connectionHeaderAndActions(tokens: tokens)

            connectionDiagnostics(tokens: tokens)

            DisclosureGroup(isExpanded: $isShowingManualFields) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField(L10n.text("ui.tailscale_address"), text: $endpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(themeStore.uiFont(.callout))
                        .padding(10)
                        .background(tokens.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    SecureField(L10n.text("ui.access_code"), text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(themeStore.uiFont(.callout))
                        .padding(10)
                        .background(tokens.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .padding(.top, 10)
            } label: {
                Label(L10n.text("ui.manual_configuration"), systemImage: "slider.horizontal.3")
                    .font(themeStore.uiFont(.callout, weight: .semibold))
                    .foregroundStyle(appStore.isConfigured ? tokens.primaryText : tokens.secondaryText)
            }

            if let error = localError ?? appStore.lastError {
                Text(error)
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(tokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(tokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tokens.border, lineWidth: 1)
        }
        .onAppear(perform: loadInitialConnectionIfNeeded)
        .sheet(isPresented: $isShowingQRCodeScanner) {
            QRCodeScannerSheet(onDismiss: {
                isShowingQRCodeScanner = false
            }, onChooseManualConnection: {
                isShowingManualFields = true
            }) { rawValue in
                await applyScannedConnection(rawValue)
            }
        }
        .confirmationDialog(
            pendingRemovalConfirmation?.title ?? L10n.text("ui.confirm_to_delete_connection_credentials"),
            isPresented: removalConfirmationBinding,
            titleVisibility: .visible,
            presenting: pendingRemovalConfirmation
        ) { confirmation in
            Button(confirmation.confirmButtonTitle, role: .destructive) {
                Task {
                    await confirmForgetCurrent(confirmation)
                }
            }
            .accessibilityIdentifier("root.connection.forget.confirm")

            Button(L10n.text("ui.cancel"), role: .cancel) {
                pendingRemovalConfirmation = nil
            }
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    private var removalConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingRemovalConfirmation != nil },
            set: { isPresented in
                if !isPresented {
                    pendingRemovalConfirmation = nil
                }
            }
        )
    }

    @ViewBuilder
    private func connectionHeaderAndActions(tokens: ThemeTokens) -> some View {
        if horizontalSizeClass == .compact {
            VStack(alignment: .leading, spacing: 14) {
                connectionSummaryRow(tokens: tokens)
                compactConnectionActions
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 14) {
                    connectionSummaryRow(tokens: tokens)
                    Spacer(minLength: 16)
                    HStack(spacing: 10) {
                        connectionActions()
                    }
                }
                VStack(alignment: .leading, spacing: 14) {
                    connectionSummaryRow(tokens: tokens)
                    HStack(spacing: 10) {
                        connectionActions()
                    }
                }
            }
        }
    }

    private func connectionSummaryRow(tokens: ThemeTokens) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(connectionTone(tokens: tokens).opacity(0.14))
                Image(systemName: "desktopcomputer")
                    .font(themeStore.uiFont(.title2, weight: .semibold))
                    .foregroundStyle(connectionTone(tokens: tokens))
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(L10n.text("ui.connect_to_mac"))
                        .font(themeStore.uiFont(.headline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                    Text(appStore.connectionStatus.title)
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                        .foregroundStyle(connectionTone(tokens: tokens))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(connectionTone(tokens: tokens).opacity(0.12), in: Capsule())
                }
                Text(appStore.isConfigured ? appStore.endpoint : L10n.text("ui.mac_connection_not_configured_yet"))
                    .font(themeStore.uiFont(.callout))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private func connectionDiagnostics(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if isConnectionTesting {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.text("ui.testing_connection"))
                        .font(themeStore.uiFont(.footnote, weight: .medium))
                        .foregroundStyle(tokens.secondaryText)
                }
            }
            if let milliseconds = appStore.lastConnectionTestDurationMillis {
                Text(L10n.format("ui.the_last_test_took_value", AppStore.connectionTestDurationText(milliseconds: milliseconds)))
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(tokens.secondaryText)
            }
            if let report = appStore.lastConnectionTestReport {
                if let failedStage = report.failedStage {
                    Text(L10n.format("ui.failed_link_value_value", failedStage.kind.title, AppStore.connectionTestDurationText(milliseconds: failedStage.durationMillis)))
                        .font(themeStore.uiFont(.footnote))
                        .foregroundStyle(tokens.warning)
                } else if let slowestStage = report.slowestStage {
                    Text(L10n.format("ui.slowest_link_value_value", slowestStage.kind.title, AppStore.connectionTestDurationText(milliseconds: slowestStage.durationMillis)))
                        .font(themeStore.uiFont(.footnote))
                        .foregroundStyle(tokens.secondaryText)
                }
            }
        }
    }

    @ViewBuilder
    private func connectionActions() -> some View {
        scanConnectionButton

        if appStore.isConfigured || isShowingManualFields {
            Button {
                Task {
                    await appStore.testConnection(
                        endpoint: endpoint,
                        token: token
                    )
                }
            } label: {
                Label(isConnectionTesting ? L10n.text("ui.under_test") : L10n.text("ui.test_connection"), systemImage: isConnectionTesting ? "timer" : "bolt.horizontal.circle")
            }
            .buttonStyle(.bordered)
            .disabled(!canSubmit)

            Button {
                Task { await saveManualConnection() }
            } label: {
                Label(isSavingConnection ? L10n.text("ui.saving") : L10n.text("ui.save_connection"), systemImage: "checkmark.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSubmit)
        }

        if appStore.isConfigured {
            Button(role: .destructive) {
                requestForgetCurrent()
            } label: {
                Label(L10n.text("ui.forget"), systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(isSavingConnection)
            .accessibilityIdentifier("root.connection.forget")
        }
    }

    private var compactConnectionActions: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(minimum: 0), spacing: 10),
                GridItem(.flexible(minimum: 0), spacing: 10)
            ],
            alignment: .leading,
            spacing: 10
        ) {
            scanConnectionCompactButton

            if appStore.isConfigured || isShowingManualFields {
                testConnectionCompactButton
                saveConnectionCompactButton
            }

            if appStore.isConfigured {
                forgetConnectionCompactButton
            }
        }
    }

    private func compactActionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(themeStore.uiFont(.callout, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
    }

    @ViewBuilder
    private var scanConnectionCompactButton: some View {
        if appStore.isConfigured {
            Button {
                isShowingQRCodeScanner = true
            } label: {
                compactActionLabel(L10n.text("ui.scan_code_to_connect"), systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(.bordered)
            .disabled(isSavingConnection)
        } else {
            Button {
                isShowingQRCodeScanner = true
            } label: {
                compactActionLabel(L10n.text("ui.scan_code_to_connect"), systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSavingConnection)
        }
    }

    private var testConnectionCompactButton: some View {
        Button {
            Task {
                await appStore.testConnection(
                    endpoint: endpoint,
                    token: token
                )
            }
        } label: {
            compactActionLabel(isConnectionTesting ? L10n.text("ui.under_test") : L10n.text("ui.test_connection"), systemImage: isConnectionTesting ? "timer" : "bolt.horizontal.circle")
        }
        .buttonStyle(.bordered)
        .disabled(!canSubmit)
    }

    private var saveConnectionCompactButton: some View {
        Button {
            Task { await saveManualConnection() }
        } label: {
            compactActionLabel(isSavingConnection ? L10n.text("ui.saving") : L10n.text("ui.save_connection"), systemImage: "checkmark.circle")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canSubmit)
    }

    private var forgetConnectionCompactButton: some View {
        Button(role: .destructive) {
            requestForgetCurrent()
        } label: {
            compactActionLabel(L10n.text("ui.forget"), systemImage: "trash")
        }
        .buttonStyle(.bordered)
        .disabled(isSavingConnection)
        .accessibilityIdentifier("root.connection.forget.compact")
    }

    @ViewBuilder
    private var scanConnectionButton: some View {
        if appStore.isConfigured {
            Button {
                isShowingQRCodeScanner = true
            } label: {
                Label(L10n.text("ui.scan_code_to_connect"), systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(.bordered)
            .disabled(isSavingConnection)
        } else {
            Button {
                isShowingQRCodeScanner = true
            } label: {
                Label(L10n.text("ui.scan_code_to_connect"), systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSavingConnection)
        }
    }

    private var canSubmit: Bool {
        !isSavingConnection &&
        !isConnectionTesting &&
        !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isConnectionTesting: Bool {
        if case .testing = appStore.connectionStatus {
            return true
        }
        return false
    }

    private func connectionTone(tokens: ThemeTokens) -> Color {
        switch appStore.connectionStatus {
        case .connected:
            return tokens.success
        case .failed:
            return tokens.warning
        case .testing:
            return tokens.accent
        case .idle:
            return appStore.isConfigured ? tokens.secondaryText : tokens.warning
        }
    }

    private func loadInitialConnectionIfNeeded() {
        guard !didLoadInitialConnection else {
            return
        }
        didLoadInitialConnection = true
        endpoint = appStore.endpoint
        token = appStore.token
    }

    private func saveManualConnection() async {
        isSavingConnection = true
        defer { isSavingConnection = false }
        do {
            let wasConfigured = appStore.isConfigured
            _ = try await sessionStore.applyConnectionSettings(
                endpoint: endpoint,
                token: token
            )
            endpoint = appStore.endpoint
            token = appStore.token
            _ = await refreshCommittedConnection(maxWait: wasConfigured ? 10 : 45)
        } catch {
            appStore.connectionStatus = .failed(error.localizedDescription)
            appStore.lastError = error.localizedDescription
            localError = error.localizedDescription
        }
    }

    private func applyScannedConnection(_ rawValue: String) async -> QRCodeScannerSubmissionResult {
        isSavingConnection = true
        do {
            let wasConfigured = appStore.isConfigured
            let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: raw) else {
                throw PairingLinkError.unsupportedURL
            }
            _ = try await sessionStore.applyPairingURL(url)
            endpoint = appStore.endpoint
            token = appStore.token
            // 配对验证成功即可退出扫码页；工作台数据在后台继续恢复。
            Task { @MainActor in
                defer { isSavingConnection = false }
                _ = await refreshCommittedConnection(maxWait: wasConfigured ? 10 : 45)
            }
            return .accepted(L10n.text("ui.this_mac_is_connected"))
        } catch is CancellationError {
            isSavingConnection = false
            localError = nil
            return .rejected(L10n.text("ui.the_code_scan_has_been_cancelled_please_scan"))
        } catch {
            isSavingConnection = false
            appStore.connectionStatus = .failed(error.localizedDescription)
            appStore.lastError = error.localizedDescription
            localError = error.localizedDescription
            return .rejected(error.localizedDescription)
        }
    }

    private func refreshCommittedConnection(maxWait: TimeInterval) async -> Bool {
        let didLoad = await sessionStore.refreshAfterConnectionCommit(maxWait: maxWait)
        if didLoad {
            localError = nil
        } else if Task.isCancelled {
            localError = nil
        } else {
            localError = appStore.lastError ?? sessionStore.errorMessage
        }
        return didLoad
    }

    private func clearPairing() async {
        do {
            try await sessionStore.clearCurrentConnectionProfile()
            endpoint = appStore.endpoint
            token = appStore.token
            localError = nil
        } catch {
            localError = error.localizedDescription
        }
    }

    private func requestForgetCurrent() {
        pendingRemovalConfirmation = .forgettingCurrent(appStore.activeConnectionProfile)
    }

    private func confirmForgetCurrent(_ confirmation: ConnectionCredentialRemovalConfirmation) async {
        guard case .current(let expectedProfileID) = confirmation.target else {
            return
        }
        guard expectedProfileID == appStore.activeConnectionProfileID else {
            // 弹窗展示期间连接可能被其它入口切换；旧确认不得作用于新的当前 Mac。
            pendingRemovalConfirmation = nil
            localError = L10n.text("ui.the_current_mac_has_changed_please_try_again")
            return
        }
        pendingRemovalConfirmation = nil
        await clearPairing()
    }
}

struct ProfileInfoRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let systemImage: String
    let title: String
    let value: String
    let detail: String
    let tone: Color
    var trailingSystemImage: String? = nil

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tone.opacity(0.12))
                Image(systemName: systemImage)
                    .font(themeStore.uiFont(.headline, weight: .semibold))
                    .foregroundStyle(tone)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        rowTitle(tokens: tokens)
                        rowValue
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        rowTitle(tokens: tokens)
                        rowValue
                    }
                }
                Text(detail)
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            if let trailingSystemImage {
                Image(systemName: trailingSystemImage)
                    .font(themeStore.uiFont(.footnote, weight: .semibold))
                    .foregroundStyle(tokens.tertiaryText)
                    .padding(.top, 11)
            }
        }
        .padding(14)
        .background(tokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tokens.border, lineWidth: 1)
        }
    }

    private func rowTitle(tokens: ThemeTokens) -> some View {
        Text(title)
            .font(themeStore.uiFont(.headline, weight: .semibold))
            .foregroundStyle(tokens.primaryText)
            .lineLimit(1)
    }

    private var rowValue: some View {
        Text(value)
            .font(themeStore.uiFont(.footnote, weight: .semibold))
            .foregroundStyle(tone)
            .lineLimit(1)
    }
}
