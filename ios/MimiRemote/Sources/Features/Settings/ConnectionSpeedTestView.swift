import SwiftUI
import UniformTypeIdentifiers

struct ConnectionSpeedTestView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var themeStore: ThemeStore
    @EnvironmentObject private var tailcatController: TailcatExperimentController
    @State private var selectedRoute: ConnectionTestRoute = .tailscale
    @State private var isRunningTest = false
    @State private var didSelectInitialRoute = false
    @State private var recordsBenchmarkSamples = false
    @State private var benchmarkScenario: ConnectionBenchmarkScenario = .warm
    @State private var benchmarkDataset = ConnectionBenchmarkDataset.load()
    @State private var benchmarkExportDocument: ConnectionBenchmarkExportDocument?
    @State private var isPresentingBenchmarkExporter = false
    @State private var benchmarkExportError: String?
    @State private var confirmsBenchmarkReset = false

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Form {
            Section(L10n.text("ui.connection_method")) {
                Picker(L10n.text("ui.connection_method"), selection: $selectedRoute) {
                    Text(ConnectionTestRoute.tailscale.title).tag(ConnectionTestRoute.tailscale)
                    Text(ConnectionTestRoute.tailcat.title).tag(ConnectionTestRoute.tailcat)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("settings.connectionSpeedTest.route")
            }

            benchmarkRecordingSection(tokens: tokens)

            Section {
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(resultTone(tokens: tokens).opacity(0.14))
                        Image(systemName: resultSystemImage)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(resultTone(tokens: tokens))
                    }
                    .frame(width: 44, height: 44)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(resultTitle)
                            .font(themeStore.uiFont(.headline, weight: .semibold))
                            .foregroundStyle(tokens.primaryText)
                        Text(selectedEndpoint ?? L10n.text("ui.tailcat_needs_address"))
                            .font(themeStore.uiFont(.caption))
                            .foregroundStyle(tokens.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 8)

                    if let report = currentReport {
                        Text(AppStore.connectionTestDurationText(milliseconds: report.totalMillis))
                            .font(themeStore.uiFont(.callout, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(resultTone(tokens: tokens))
                            .lineLimit(1)
                    }
                }

                Button {
                    Task { await runSelectedTest() }
                } label: {
                    HStack(spacing: 8) {
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "bolt.horizontal.circle")
                        }
                        Text(isTesting ? L10n.text("ui.testing_speed") : currentReport == nil ? L10n.text("ui.start_speed_test") : L10n.text("ui.retest_speed"))
                    }
                    .font(themeStore.uiFont(.body, weight: .semibold))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canRunTest)
                .accessibilityIdentifier("settings.connectionSpeedTest.run")
            } header: {
                Text(selectedRoute.title)
            } footer: {
                Text(testFooter)
            }

            if let report = currentReport {
                Section(L10n.text("ui.speed_test_results")) {
                    connectionSpeedResultSummary(report: report, tokens: tokens)
                        // 把结果概览作为一个内容自适应的 Form 行，避免系统 LabeledContent
                        // 在部分 iOS 26/27 布局中把最后一行拉伸到整屏高度。
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                }

                Section(L10n.text("ui.segmentation_takes_time")) {
                    ForEach(report.stages) { stage in
                        ConnectionSpeedTestStageRow(stage: stage)
                    }
                }

                if let diagnostics = report.gatewayDiagnostics {
                    Section(L10n.text("ui.gateway_observation")) {
                        if let connection = diagnostics.relatedConnection {
                            ConnectionSpeedMetricRow(
                                title: L10n.text("ui.mac_upstream_dialing"),
                                value: AppStore.connectionTestDurationText(milliseconds: connection.upstreamDialMillis)
                            )
                        }
                        if let rpc = diagnostics.latestRPC {
                            ConnectionSpeedMetricRow(
                                title: L10n.text("ui.recent_rpcs"),
                                value: AppStore.connectionTestDurationText(milliseconds: rpc.latencyMillis)
                            )
                        }
                        if diagnostics.writeBackMillisMax > 0 {
                            ConnectionSpeedMetricRow(
                                title: L10n.text("ui.write_back_to_device"),
                                value: AppStore.connectionTestDurationText(milliseconds: diagnostics.writeBackMillisMax)
                            )
                        }
                    }
                }
            }
        }
        .themedSettingsForm(tokens: tokens)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .settingsCanvasBackground(tokens: tokens)
        .navigationTitle(L10n.text("ui.connection_speed_test"))
        .tint(tokens.accent)
        .onAppear {
            guard !didSelectInitialRoute else { return }
            didSelectInitialRoute = true
            selectedRoute = appStore.activeConnectionRoute == .tailcat ? .tailcat : .tailscale
        }
        .fileExporter(
            isPresented: $isPresentingBenchmarkExporter,
            document: benchmarkExportDocument,
            contentType: ConnectionBenchmarkExportDocument.contentType,
            defaultFilename: benchmarkExportFilename
        ) { result in
            if case .failure(let error) = result {
                benchmarkExportError = error.localizedDescription
            }
        }
        .alert(L10n.text("ui.connection_benchmark_export_failed"), isPresented: benchmarkExportErrorBinding) {
            Button(L10n.text("ui.got_it"), role: .cancel) {}
        } message: {
            Text(benchmarkExportError ?? L10n.text("ui.please_try_again_later"))
        }
        .confirmationDialog(
            L10n.text("ui.connection_benchmark_clear_confirmation"),
            isPresented: $confirmsBenchmarkReset,
            titleVisibility: .visible
        ) {
            Button(L10n.text("ui.connection_benchmark_clear"), role: .destructive) {
                benchmarkDataset = .clear()
            }
            Button(L10n.text("ui.cancel"), role: .cancel) {}
        }
    }

    @ViewBuilder
    private func benchmarkRecordingSection(tokens: ThemeTokens) -> some View {
        Section {
            Toggle(L10n.text("ui.connection_benchmark_record_samples"), isOn: $recordsBenchmarkSamples)
                .accessibilityIdentifier("settings.connectionSpeedTest.benchmark.enabled")
                .disabled(isTesting)

            if recordsBenchmarkSamples {
                Picker(L10n.text("ui.connection_benchmark_scenario"), selection: $benchmarkScenario) {
                    ForEach(ConnectionBenchmarkScenario.allCases) { scenario in
                        Text(scenario.title).tag(scenario)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.connectionSpeedTest.benchmark.scenario")
                .disabled(isTesting)

                ForEach(ConnectionTestRoute.allCases, id: \.rawValue) { route in
                    benchmarkProgressRow(route: route, tokens: tokens)
                }

                if !benchmarkDataset.samples.isEmpty {
                    HStack(spacing: 12) {
                        Button {
                            prepareBenchmarkExport()
                        } label: {
                            Label(L10n.text("ui.connection_benchmark_export"), systemImage: "square.and.arrow.up")
                        }
                        .disabled(isTesting)

                        Spacer(minLength: 8)

                        Button(role: .destructive) {
                            confirmsBenchmarkReset = true
                        } label: {
                            Text(L10n.text("ui.connection_benchmark_clear"))
                        }
                        .disabled(isTesting)
                    }
                }
            }
        } header: {
            Text(L10n.text("ui.connection_benchmark_title"))
        } footer: {
            if recordsBenchmarkSamples {
                Text(benchmarkScenario.footer)
            } else {
                Text(L10n.text("ui.connection_benchmark_privacy_footer"))
            }
        }
    }

    private func benchmarkProgressRow(
        route: ConnectionTestRoute,
        tokens: ThemeTokens
    ) -> some View {
        let statistics = benchmarkDataset.statistics(route: route, scenario: benchmarkScenario)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(route.title)
                    .foregroundStyle(tokens.primaryText)
                Text(L10n.format(
                    "ui.connection_benchmark_progress_value",
                    String(statistics.sampleCount),
                    String(ConnectionBenchmarkDataset.targetSampleCount)
                ))
                .font(themeStore.uiFont(.caption))
                .foregroundStyle(tokens.secondaryText)
            }

            Spacer(minLength: 8)

            if let median = statistics.medianMillis, let p95 = statistics.p95Millis {
                Text(L10n.format(
                    "ui.connection_benchmark_latency_value",
                    AppStore.connectionTestDurationText(milliseconds: median),
                    AppStore.connectionTestDurationText(milliseconds: p95)
                ))
                .font(themeStore.uiFont(.caption, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(tokens.secondaryText)
                .multilineTextAlignment(.trailing)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func connectionSpeedResultSummary(
        report: ConnectionTestReport,
        tokens: ThemeTokens
    ) -> some View {
        VStack(spacing: 0) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 14) {
                        connectionSpeedTotalMetric(report: report, tokens: tokens)
                        Divider()
                            .overlay(tokens.border.opacity(0.72))
                        connectionSpeedBottleneckMetric(report: report, tokens: tokens)
                    }
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        connectionSpeedTotalMetric(report: report, tokens: tokens)

                        Divider()
                            .overlay(tokens.border.opacity(0.72))
                            .frame(height: 68)

                        connectionSpeedBottleneckMetric(report: report, tokens: tokens)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)

            Divider()
                .overlay(tokens.border.opacity(0.72))

            connectionSpeedResultDetailRow(
                title: L10n.text("ui.test_time"),
                tokens: tokens
            ) {
                Text(report.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(tokens.secondaryText)
            }

            if report.route == .tailcat, let diagnostic = tailcatController.lastDiagnostic {
                Divider()
                    .overlay(tokens.border.opacity(0.72))
                    .padding(.leading, 16)

                connectionSpeedResultDetailRow(
                    title: "Tailcat",
                    tokens: tokens
                ) {
                    Text(diagnostic.summary)
                        .foregroundStyle(tokens.secondaryText)
                }
            }

            if let networkPath = report.tailscaleNetworkPath {
                Divider()
                    .overlay(tokens.border.opacity(0.72))
                    .padding(.leading, 16)

                connectionSpeedResultDetailRow(
                    title: L10n.text("ui.tailscale_network_path"),
                    tokens: tokens
                ) {
                    connectionSpeedNetworkPathBadge(
                        networkPath: networkPath,
                        tokens: tokens
                    )
                }
            }
        }
        .background(tokens.surface)
    }

    private func connectionSpeedTotalMetric(
        report: ConnectionTestReport,
        tokens: ThemeTokens
    ) -> some View {
        connectionSpeedHighlightMetric(
            title: L10n.text("ui.total_time_spent"),
            systemImage: "timer",
            value: AppStore.connectionTestDurationText(milliseconds: report.totalMillis),
            detail: nil,
            tone: resultTone(tokens: tokens),
            tokens: tokens
        )
    }

    @ViewBuilder
    private func connectionSpeedBottleneckMetric(
        report: ConnectionTestReport,
        tokens: ThemeTokens
    ) -> some View {
        if let failedStage = report.failedStage {
            connectionSpeedHighlightMetric(
                title: L10n.text("ui.failure_link"),
                systemImage: "exclamationmark.triangle.fill",
                value: failedStage.kind.title,
                detail: AppStore.connectionTestDurationText(milliseconds: failedStage.durationMillis),
                tone: tokens.warning,
                tokens: tokens
            )
        } else if let slowestStage = report.slowestStage {
            connectionSpeedHighlightMetric(
                title: L10n.text("ui.slowest_link"),
                systemImage: "gauge.with.dots.needle.67percent",
                value: AppStore.connectionTestDurationText(milliseconds: slowestStage.durationMillis),
                detail: slowestStage.kind.title,
                tone: tokens.warning,
                tokens: tokens
            )
        }
    }

    private func connectionSpeedHighlightMetric(
        title: String,
        systemImage: String,
        value: String,
        detail: String?,
        tone: Color,
        tokens: ThemeTokens
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: systemImage)
                .font(themeStore.uiFont(.caption, weight: .medium))
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(1)

            Text(value)
                .font(themeStore.uiFont(.title3, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tone)
                .lineLimit(1)

            if let detail {
                Text(detail)
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func connectionSpeedResultDetailRow<Value: View>(
        title: String,
        tokens: ThemeTokens,
        @ViewBuilder value: () -> Value
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                Text(title)
                    .font(themeStore.uiFont(.callout))
                    .foregroundStyle(tokens.primaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 12)

                value()
                    .font(themeStore.uiFont(.callout))
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: true, vertical: false)
            }

            // 窄屏或大字号时让右侧状态整体换到下一行，避免状态文字被挤成逐字换行。
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(themeStore.uiFont(.callout))
                    .foregroundStyle(tokens.primaryText)

                value()
                    .font(themeStore.uiFont(.callout))
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func connectionSpeedNetworkPathBadge(
        networkPath: TailscaleNetworkPathResponse,
        tokens: ThemeTokens
    ) -> some View {
        let tone = tailscaleNetworkPathTone(networkPath.kind, tokens: tokens)

        return HStack(spacing: 6) {
            Image(systemName: networkPath.kind.settingsSystemImage)
                .font(.system(size: 13, weight: .semibold))

            Text(networkPath.localizedSummary)
                .font(themeStore.uiFont(.footnote, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(tone)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(tone.opacity(0.11), in: Capsule())
        .overlay {
            Capsule()
                .stroke(tone.opacity(0.18), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
    }

    private var isTesting: Bool { isRunningTest }

    private var canRunTest: Bool {
        appStore.isConfigured
            && !isTesting
            && selectedEndpoint != nil
            && !appStore.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectedEndpoint: String? {
        let value: String?
        switch selectedRoute {
        case .tailscale:
            value = appStore.endpoint
        case .tailcat:
            value = tailcatController.isEnabled ? appStore.tailcatExperimentEndpoint : nil
        }
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var currentReport: ConnectionTestReport? {
        guard appStore.lastConnectionTestReport?.route == selectedRoute else { return nil }
        return appStore.lastConnectionTestReport
    }

    private var testFooter: String {
        if selectedRoute == .tailcat, selectedEndpoint == nil {
            return tailcatController.isEnabled
                ? L10n.text("ui.tailcat_needs_address")
                : L10n.text("ui.tailcat_experiment_disabled")
        }
        return canRunTest || isTesting
            ? L10n.text("ui.check_iphone_ipad_to_mac_assistant_authentication_gateway")
            : L10n.text("ui.there_are_currently_no_connection_credentials_available_please")
    }

    private func runSelectedTest() async {
        let route = selectedRoute
        let scenario = benchmarkScenario
        let shouldRecordBenchmark = recordsBenchmarkSamples
        guard var endpoint = selectedEndpoint else { return }
        isRunningTest = true
        defer { isRunningTest = false }

        var preparation: ConnectionBenchmarkPreparation
        var preparationMillis: Int?
        var preparationSucceeded = true
        switch route {
        case .tailscale:
            preparation = .tailscaleSystemManaged
        case .tailcat where shouldRecordBenchmark && scenario == .cold:
            preparation = .tailcatControlledRestart
            let preparationStartedAt = Date()
            preparationSucceeded = await tailcatController.recoverRouteFromForeground(appStore: appStore)
            preparationMillis = elapsedMilliseconds(since: preparationStartedAt)
            guard preparationSucceeded, let restartedEndpoint = selectedEndpoint else {
                appStore.lastConnectionTestDurationMillis = nil
                appStore.lastConnectionTestReport = nil
                if shouldRecordBenchmark {
                    recordBenchmarkSample(
                        route: route,
                        scenario: scenario,
                        endpoint: endpoint,
                        report: nil,
                        tailcatDiagnostic: nil,
                        preparation: preparation,
                        preparationMillis: preparationMillis,
                        preparationSucceeded: false
                    )
                }
                return
            }
            endpoint = restartedEndpoint
        case .tailcat:
            preparation = .tailcatReusedClient
        }

        await appStore.testConnection(
            endpoint: endpoint,
            token: appStore.token,
            route: route,
            affectsConnectionStatus: route.isActive(in: appStore)
        )

        var tailcatDiagnostic: TailcatPathDiagnostic?
        if route == .tailcat {
            // 路径探测放在业务测速之后，避免 DISCO Ping 预热冷连接样本。
            await tailcatController.refreshPathDiagnostic()
            tailcatDiagnostic = tailcatController.lastDiagnostic
        }
        guard shouldRecordBenchmark,
              let report = appStore.lastConnectionTestReport,
              report.route == route else { return }
        recordBenchmarkSample(
            route: route,
            scenario: scenario,
            endpoint: endpoint,
            report: report,
            tailcatDiagnostic: tailcatDiagnostic,
            preparation: preparation,
            preparationMillis: preparationMillis,
            preparationSucceeded: preparationSucceeded
        )
    }

    private func recordBenchmarkSample(
        route: ConnectionTestRoute,
        scenario: ConnectionBenchmarkScenario,
        endpoint: String,
        report: ConnectionTestReport?,
        tailcatDiagnostic: TailcatPathDiagnostic?,
        preparation: ConnectionBenchmarkPreparation,
        preparationMillis: Int?,
        preparationSucceeded: Bool
    ) {
        benchmarkDataset.append(ConnectionBenchmarkSample.make(
            route: route,
            scenario: scenario,
            endpoint: endpoint,
            report: report,
            tailcatDiagnostic: tailcatDiagnostic,
            preparation: preparation,
            preparationMillis: preparationMillis,
            preparationSucceeded: preparationSucceeded
        ))
        benchmarkDataset.persist()
    }

    private func prepareBenchmarkExport() {
        do {
            let data = try benchmarkDataset.encodedExport(
                appVersion: SessionLogExportBuilder.currentAppVersion(),
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString
            )
            benchmarkExportDocument = ConnectionBenchmarkExportDocument(data: data)
            isPresentingBenchmarkExporter = true
        } catch {
            benchmarkExportError = error.localizedDescription
        }
    }

    private var benchmarkExportErrorBinding: Binding<Bool> {
        Binding(
            get: { benchmarkExportError != nil },
            set: { isPresented in
                if !isPresented {
                    benchmarkExportError = nil
                }
            }
        )
    }

    private var benchmarkExportFilename: String {
        "Mimi-Connection-Benchmark-\(Self.filenameTimestamp(Date())).json"
    }

    private func elapsedMilliseconds(since date: Date) -> Int {
        max(0, Int((Date().timeIntervalSince(date) * 1_000).rounded()))
    }

    private static func filenameTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private var resultTitle: String {
        if isTesting {
            return L10n.text("ui.testing_full_link")
        }
        if currentReport?.failedStage != nil {
            return L10n.text("ui.connection_test_failed")
        }
        if currentReport != nil {
            return L10n.text("ui.the_connection_link_is_normal")
        }
        return appStore.isConfigured ? L10n.text("ui.you_can_start_speed_measurement") : L10n.text("ui.not_connected_to_mac_yet")
    }

    private var resultSystemImage: String {
        if isTesting {
            return "timer"
        }
        if currentReport?.failedStage != nil {
            return "exclamationmark.triangle.fill"
        }
        if currentReport != nil {
            return "checkmark.circle.fill"
        }
        return "speedometer"
    }

    private func resultTone(tokens: ThemeTokens) -> Color {
        if isTesting {
            return tokens.accent
        }
        if currentReport?.failedStage != nil {
            return tokens.warning
        }
        return currentReport == nil ? tokens.secondaryText : tokens.success
    }

    private func tailscaleNetworkPathTone(
        _ kind: TailscaleNetworkPathResponse.Kind,
        tokens: ThemeTokens
    ) -> Color {
        switch kind {
        case .direct:
            return tokens.success
        case .peerRelay, .derp:
            return tokens.warning
        case .notTailscale, .unknown, .unavailable:
            return tokens.secondaryText
        }
    }
}

private extension ConnectionTestRoute {
    var title: String {
        switch self {
        case .tailscale:
            return L10n.text("ui.connection_speed_test_route_tailscale")
        case .tailcat:
            return L10n.text("ui.connection_speed_test_route_tailcat")
        }
    }

    @MainActor
    func isActive(in appStore: AppStore) -> Bool {
        switch self {
        case .tailscale:
            return appStore.activeConnectionRoute != .tailcat
        case .tailcat:
            return appStore.activeConnectionRoute == .tailcat
        }
    }
}

private extension ConnectionBenchmarkScenario {
    var title: String {
        switch self {
        case .cold:
            return L10n.text("ui.connection_benchmark_scenario_cold")
        case .warm:
            return L10n.text("ui.connection_benchmark_scenario_warm")
        case .networkRecovery:
            return L10n.text("ui.connection_benchmark_scenario_recovery")
        }
    }

    var footer: String {
        switch self {
        case .cold:
            return L10n.text("ui.connection_benchmark_cold_footer")
        case .warm:
            return L10n.text("ui.connection_benchmark_warm_footer")
        case .networkRecovery:
            return L10n.text("ui.connection_benchmark_recovery_footer")
        }
    }
}

extension TailscaleNetworkPathResponse {
    var localizedSummary: String {
        switch kind {
        case .direct:
            return L10n.text("ui.tailscale_path_direct")
        case .peerRelay:
            return L10n.text("ui.tailscale_path_peer_relay")
        case .derp:
            let title = L10n.text("ui.tailscale_path_derp")
            guard let relayRegion,
                  !relayRegion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return title
            }
            return "\(title) · \(relayRegion.uppercased())"
        case .notTailscale:
            return L10n.text("ui.tailscale_path_not_tailscale")
        case .unknown:
            return L10n.text("ui.tailscale_path_unknown")
        case .unavailable:
            return L10n.text("ui.tailscale_path_unavailable")
        }
    }
}

extension TailscaleNetworkPathResponse.Kind {
    var settingsSystemImage: String {
        switch self {
        case .direct:
            return "bolt.horizontal.circle.fill"
        case .peerRelay:
            return "arrow.left.arrow.right.circle"
        case .derp:
            return "network"
        case .notTailscale:
            return "wifi"
        case .unknown, .unavailable:
            return "questionmark.circle"
        }
    }
}

private struct ConnectionSpeedTestStageRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    let stage: ConnectionTestStageTiming

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(alignment: .center, spacing: 12) {
            Image(systemName: stage.status.isFailed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(stage.status.isFailed ? tokens.warning : tokens.success)

            VStack(alignment: .leading, spacing: 2) {
                Text(stage.kind.title)
                    .foregroundStyle(tokens.primaryText)
                Text(stage.kind.detail)
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(AppStore.connectionTestDurationText(milliseconds: stage.durationMillis))
                .font(themeStore.uiFont(.callout, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(stage.status.isFailed ? tokens.warning : tokens.secondaryText)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.format("ui.connection_test_stage_accessibility", stage.kind.title, stage.status.isFailed ? L10n.text("ui.failed_status") : L10n.text("ui.success")))
        .accessibilityValue(AppStore.connectionTestDurationText(milliseconds: stage.durationMillis))
    }
}

private struct ConnectionSpeedMetricRow: View {
    let title: String
    let value: String

    var body: some View {
        LabeledContent(title) {
            Text(value)
                .monospacedDigit()
        }
    }
}

private struct ConnectionBenchmarkExportDocument: FileDocument {
    static let contentType = UTType.json
    static var readableContentTypes: [UTType] { [.json] }

    private let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// 视觉基线按状态逐个录制，因此对测试可见；页面之外没有其他调用方。
