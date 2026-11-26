import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticsView: View {
    let store: HostStore
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var diagnosticsStore: DiagnosticsStore?
    @State private var expandsDoctorDetails = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HostStatusHeader(lifecycle: store.lifecycle, compact: true, showsDetail: false)
                Button("重新检查") {
                    Task {
                        await diagnosticsStore?.refreshAll()
                        await store.refreshDiagnostics()
                    }
                }
                .disabled(diagnosticsStore?.isChecking == true || diagnosticsStore?.isApplyingFix == true)
            }
            .padding(18)

            Divider()

            HSplitView {
                checksPane
                    .frame(minWidth: 340)

                DiagnosticLogsPane(store: store)
                    .frame(minWidth: 420)
            }

            if let fixes = diagnosticsStore?.appliedFixes, !fixes.isEmpty {
                Divider()
                Text("已修复：\(fixes.joined(separator: "；"))")
                    .font(.caption)
                    .foregroundStyle(Color.mimiPrimary)
                    .padding(10)
            }

            if let errorMessage = visibleBottomError {
                Divider()
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(10)
            }
        }
        .fileImporter(
            isPresented: Binding(
                get: { diagnosticsStore?.isPathPickerPresented ?? false },
                set: { diagnosticsStore?.isPathPickerPresented = $0 }
            ),
            allowedContentTypes: allowedPickerTypes,
            allowsMultipleSelection: false
        ) { result in
            Task { await diagnosticsStore?.completePathPicker(with: try? result.get().first) }
        } onCancellation: {
            Task { await diagnosticsStore?.completePathPicker(with: nil) }
        }
        .task {
            let controller = ensureDiagnosticsStore()
            store.requestedDiagnosticsFocus = nil
            await controller.runPreflight()
            await store.refreshDiagnostics()
        }
        .onChange(of: store.requestedDiagnosticsFocus) { _, focus in
            guard focus != nil else { return }
            store.requestedDiagnosticsFocus = nil
            Task { await diagnosticsStore?.runPreflight() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard let diagnosticsStore, !diagnosticsStore.isPathPickerPresented, !diagnosticsStore.isApplyingFix else { return }
            Task { await diagnosticsStore.runPreflight() }
        }
        .onDisappear {
            diagnosticsStore?.cancel()
        }
    }

    private var allowedPickerTypes: [UTType] {
        switch diagnosticsStore?.pendingPathPicker {
        case .workspaceRoot, .none:
            [.folder]
        case .runtimeBinary:
            [.item]
        }
    }

    private var visibleBottomError: String? {
        if let actionError = diagnosticsStore?.actionError {
            return actionError.message
        }
        if let lastError = store.lastError, !lastError.isEmpty {
            return "服务操作未完成，请重新检查当前状态。"
        }
        return nil
    }

    @ViewBuilder
    private var checksPane: some View {
        if let diagnosticsStore {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let recovery = diagnosticsStore.recoveryDiagnostic {
                        HostRecoveryReadOnlyCard(diagnostic: recovery)
                    }

                    if let preflightError = diagnosticsStore.preflightError,
                       preflightError != diagnosticsStore.recoveryDiagnostic
                    {
                        OnboardingDiagnosticBanner(
                            diagnostic: preflightError,
                            isWorking: diagnosticsStore.isChecking || diagnosticsStore.isApplyingFix,
                            onPrimaryAction: {
                                Task { await diagnosticsStore.performDiagnosticAction(preflightError) }
                            },
                            onRetry: {
                                Task { await diagnosticsStore.runPreflight() }
                            }
                        )
                    }

                    InfoCard("环境与服务预检") {
                        if diagnosticsStore.isChecking && diagnosticsStore.checks.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("正在执行只读预检…")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        } else if diagnosticsStore.checks.isEmpty {
                            Text("暂未获取到结构化预检结果，请点击「重新检查」。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(diagnosticsStore.checks) { check in
                                PreflightDiagnosticRow(
                                    store: diagnosticsStore,
                                    check: check
                                )
                                if check.id != diagnosticsStore.checks.last?.id {
                                    Divider().opacity(0.35)
                                }
                            }
                        }
                    }

                    if diagnosticsStore.canReadDoctor {
                        // doctor --json 仅作只读中文标题与脱敏折叠详情展示，绝不渲染可点击修复按钮。
                        DisclosureGroup("底层诊断详情（仅展示）", isExpanded: $expandsDoctorDetails) {
                            VStack(alignment: .leading, spacing: 8) {
                                if diagnosticsStore.doctorChecks.isEmpty {
                                    Button("读取底层诊断详情") { Task { await diagnosticsStore.runReadOnlyDoctor() } }
                                }
                                ForEach(diagnosticsStore.doctorChecks) { check in
                                    DoctorDisplayCheckRow(check: check)
                                    if check.id != diagnosticsStore.doctorChecks.last?.id {
                                        Divider().opacity(0.3)
                                    }
                                }
                            }
                            .padding(.top, 8)
                        }
                        .padding(14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(16)
            }
        } else {
            ProgressView("正在加载诊断信息…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func ensureDiagnosticsStore() -> DiagnosticsStore {
        if let diagnosticsStore { return diagnosticsStore }
        let created = DiagnosticsStore(
            dependencies: .live(hostStore: store, openDashboard: {
                openWindow(id: AppWindow.dashboard.rawValue)
                activateApplication()
            }) { target in
                handleOpenSettings(target)
            },
            verifiedCapability: store.verifiedOnboardingCapability
        )
        diagnosticsStore = created
        return created
    }

    private func handleOpenSettings(_ target: OnboardingSettingsTarget) {
        switch target {
        case .loginItems:
            store.openLoginItemsSettings()
        case .filesAndFolders:
            store.openFilesAndFoldersSettings()
        case .localNetwork:
            store.openLocalNetworkSettings()
        case .photos:
            store.openPhotosPrivacySettings()
        case .fullDiskAccess:
            store.openFullDiskAccessSettings()
        case .dateTime:
            store.openDateTimeSettings()
        case .assistants:
            store.requestedSettingsSection = .assistants
            openSettings()
            activateApplication()
        case .managedConnection:
            store.requestedSettingsSection = .connections
            openSettings()
            activateApplication()
        case .connections:
            openWindow(id: AppWindow.pairing.rawValue)
            activateApplication()
        case .hostRecovery, .windowsFirewall, .windowsNetworkProfile:
            break
        }
    }

    private func activateApplication() {
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}

private struct HostRecoveryReadOnlyCard: View {
    let diagnostic: OnboardingResolvedDiagnostic

    var body: some View {
        InfoCard("只读配置恢复信息") {
            Text(diagnostic.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let configPath = diagnostic.configPath {
                KeyValueRow(key: "保留的配置", value: configPath)
            }
            if let recoveryPath = diagnostic.recoveryPath {
                KeyValueRow(key: "恢复参考位置", value: recoveryPath)
            }

            Text("诊断界面不会自动覆盖配置，也不会轮换宿主配对身份（Token），原有配置文件已完整保留。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PreflightDiagnosticRow: View {
    let store: DiagnosticsStore
    let check: OnboardingCheck
    @State private var expandsCandidates = false

    var body: some View {
        let resolved = store.diagnostic(for: check)
        let primaryFix = store.clickablePrimaryFix(for: check)
        let secondaryFix = store.clickableSecondaryFix(for: check)
        let isSkipped = store.skippedCheckIDs.contains(check.id)

        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                OnboardingStateIcon(state: check.state)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(check.id.localizedTitle)
                            .font(.callout.weight(.semibold))
                        if let version = check.selectedOrDetectedVersion,
                           version.range(of: #"^v?[0-9]{1,6}(?:\.[0-9]{1,6}){1,2}(?:-(?:alpha|beta|rc)\.?[0-9]{0,4})?\z"#, options: .regularExpression) != nil {
                            Text("v\(version)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        if check.blocking {
                            Text("需先处理")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.red)
                        } else if isSkipped {
                            Text("已跳过")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(rowMessage(resolved: resolved))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if primaryFix != nil || secondaryFix != nil {
                        HStack(spacing: 8) {
                            if let primaryFix {
                                Button(OnboardingActionLabels.primaryTitle(
                                    for: primaryFix,
                                    code: resolved?.code,
                                    isConfigured: store.report?.configured ?? false
                                )) {
                                    Task { await store.performCheckPrimaryAction(for: check) }
                                }
                                .controlSize(.small)
                                .disabled(store.isChecking || store.isApplyingFix)
                            }
                            if let secondaryFix {
                                Button(secondaryFix.label) {
                                    Task { await store.performCheckSecondaryAction(for: check) }
                                }
                                .controlSize(.small)
                                .disabled(store.isChecking || store.isApplyingFix)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
            }

            if let candidates = check.candidates, !candidates.isEmpty {
                DisclosureGroup("已检查的位置（\(candidates.count)）", isExpanded: $expandsCandidates) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(candidates.enumerated()), id: \.offset) { index, candidate in
                            HStack(spacing: 8) {
                                Text("候选位置 \(index + 1)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 6)
                                Text(OnboardingActionLabels.candidateOutcome(candidate.outcome))
                                    .font(.caption2)
                                    .foregroundStyle(candidate.outcome == .selected ? Color.mimiSuccess : .secondary)
                            }
                        }
                    }
                    .padding(.top, 4)
                    .padding(.leading, 20)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func rowMessage(resolved: OnboardingResolvedDiagnostic?) -> String {
        if check.state == .checking {
            return "正在检查\(check.id.localizedTitle)…"
        }
        if check.state == .ok {
            return resolved?.message ?? "\(check.id.localizedTitle)已就绪。"
        }
        return resolved?.message ?? OnboardingCopyCatalog.safeFallbackCopy
    }
}

private struct DoctorDisplayCheckRow: View {
    let check: DoctorDisplayCheck
    @State private var expandsDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: check.ok ? "checkmark.circle.fill" : check.isWarning ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
                    .foregroundStyle(check.ok ? Color.mimiPrimary : check.isWarning ? Color.orange : Color.red)
                VStack(alignment: .leading, spacing: 3) {
                    Text(check.localizedTitle)
                        .font(.callout.weight(.medium))
                    Text(check.sanitizedMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = check.sanitizedDetail, !check.ok {
                        DisclosureGroup("参考说明（只读）", isExpanded: $expandsDetail) {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .padding(.top, 2)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct DiagnosticLogsPane: View {
    let store: HostStore
    @State private var confirmsClear = false
    @State private var exportDocument: DiagnosticLogDocument?
    @State private var presentsExporter = false
    @State private var exportError: String?
    @State private var expandsSanitizedLogs = false

    private func revealDebugLog() {
        let url = AgentdSupervisorCommand.debugLogURL(homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    var body: some View {
        let sanitizedLogs = DiagnosticLogSanitizer.eventLines(store.recentLogs)

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("诊断日志")
                    .font(.headline)
                Spacer()
                if store.isLoadingDiagnostics {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("刷新") {
                    exportError = nil
                    Task { await store.refreshDiagnostics() }
                }
                .disabled(isWorking)
                Button("导出安全日志…") { Task { await prepareExport() } }
                    .disabled(isWorking)
                Button("清除…", role: .destructive) { confirmsClear = true }
                    .disabled(isWorking)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("详细记录（15 分钟）", isOn: detailedLoggingBinding)
                        .toggleStyle(.switch)
                        .disabled(isWorking || store.diagnosticsStatus == nil)

                    Text(statusDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Label("仅记录在当前 Mac，不会自动上传；展示与导出均已脱敏。", systemImage: "desktopcomputer")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(alignment: .firstTextBaseline) {
                        Text("详细记录期间，还会在本机调试日志里记下关键处的方法名、会话 ID 与错误原因，便于排查通道问题；不含消息内容，也不会进入安全日志导出。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("在访达中显示调试日志") { revealDebugLog() }
                            .controlSize(.small)
                    }

                    if let status = store.diagnosticsStatus {
                        Divider()
                        DiagnosticCapacityView(status: status)
                    } else if store.isLoadingDiagnostics {
                        Text("正在读取本机诊断状态…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ContentUnavailableView(
                            "诊断服务不可用",
                            systemImage: "exclamationmark.triangle",
                            description: Text("请确认 Mimi Remote Mac 服务正在运行，然后重试。")
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if sanitizedLogs.isEmpty {
                ContentUnavailableView(
                    "暂无安全诊断日志",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("必要的失败日志会默认保留；开启详细记录可临时补充排查信息。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DisclosureGroup("最近安全日志（已脱敏，\(sanitizedLogs.count) 条）", isExpanded: $expandsSanitizedLogs) {
                    ScrollView {
                        Text(sanitizedLogs.joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .frame(maxHeight: .infinity)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if visibleError != nil {
                Label("诊断日志操作未完成，请刷新后重试。", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .confirmationDialog(
            "清除本机诊断日志？",
            isPresented: $confirmsClear,
            titleVisibility: .visible
        ) {
            Button("清除日志", role: .destructive) {
                Task { await store.clearDiagnostics() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前 Mac 上已保留的必要失败日志和临时详细日志都会删除，无法恢复。")
        }
        .fileExporter(
            isPresented: $presentsExporter,
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: "mimi-remote-safe-diagnostics.jsonl"
        ) { result in
            if case .failure(let error) = result {
                exportError = error.localizedDescription
            }
            exportDocument = nil
        }
        .task(id: store.diagnosticsStatus?.expiresAt) {
            await refreshAfterExpiration()
        }
    }

    private var isWorking: Bool {
        store.isLoadingDiagnostics || store.isUpdatingDiagnostics || store.isExportingDiagnostics
    }

    private var detailedLoggingBinding: Binding<Bool> {
        Binding(
            get: { store.diagnosticsStatus?.enabled ?? false },
            set: { enabled in
                Task { await store.setDetailedDiagnostics(enabled) }
            }
        )
    }

    private var statusDescription: String {
        guard let status = store.diagnosticsStatus else {
            return "必要失败日志默认保留；当前无法确认详细记录状态。"
        }
        if status.enabled {
            if let expiration = status.expirationDate {
                return "详细记录将在 \(expiration.formatted(date: .abbreviated, time: .shortened)) 自动关闭。必要失败日志仍会继续保留。"
            }
            return "详细记录已开启；到期时间暂不可用。必要失败日志仍会继续保留。"
        }
        return "详细记录已关闭。保留最近 \(status.retentionDays) 天的日志，运行期间定期清理过期记录。"
    }

    private var visibleError: String? {
        exportError ?? store.diagnosticsStatusError ?? store.diagnosticsLogError
    }

    private func prepareExport() async {
        exportError = nil
        guard let lines = await store.diagnosticExportLines() else { return }
        exportDocument = DiagnosticLogDocument(lines: DiagnosticLogSanitizer.eventLines(lines))
        presentsExporter = true
    }

    private func refreshAfterExpiration() async {
        guard store.diagnosticsStatus?.enabled == true,
              let expiration = store.diagnosticsStatus?.expirationDate else { return }
        let wait = max(0, expiration.timeIntervalSinceNow) + 0.5
        do {
            try await Task.sleep(for: .seconds(wait))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        await store.refreshDiagnostics()
    }
}

private struct DiagnosticCapacityView: View {
    let status: AgentDiagnosticsStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: Double(status.totalBytes), total: Double(max(status.maxTotalBytes, 1)))
            HStack {
                Text("已用 \(Self.bytes(status.totalBytes)) / \(Self.bytes(status.maxTotalBytes))")
                Spacer()
                Text("最近 \(status.retentionDays) 天")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("当前文件 \(Self.bytes(status.currentBytes))，上一文件 \(Self.bytes(status.previousBytes))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if status.debugBytes > 0 {
                Text("本机调试日志 \(Self.bytes(status.debugBytes))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if status.droppedRecords > 0 {
                Label(
                    "有 \(status.droppedRecords) 条记录未保存，报告可能不完整。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

private struct DiagnosticLogDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]
    let contents: String

    init(lines: [String]) {
        contents = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    init(configuration: ReadConfiguration) throws {
        contents = configuration.file.regularFileContents.map {
            String(decoding: $0, as: UTF8.self)
        } ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(contents.utf8))
    }
}
