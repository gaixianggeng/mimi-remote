import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticsView: View {
    let store: HostStore
    @State private var confirmsCodexSessionRepair = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HostStatusHeader(lifecycle: store.lifecycle, compact: true)
                Button("重新检查") { Task { await store.runDoctor(fix: false) } }
                Button("修复安全问题") { Task { await store.runDoctor(fix: true) } }
                    .disabled(store.isBusy)
                Button("修复共享运行环境…") { confirmsCodexSessionRepair = true }
                    .disabled(store.isBusy || store.owner != .macApp)
                Button("登录项设置…") { store.openLoginItemsSettings() }
            }
            .padding(18)

            Divider()

            HSplitView {
                List(store.doctor?.checks ?? []) { check in
                    DiagnosticCheckRow(check: check)
                }
                .frame(minWidth: 300)

                DiagnosticLogsPane(store: store)
                    .frame(minWidth: 430)
            }

            if !store.appliedFixes.isEmpty {
                Divider()
                Text("已修复：\(store.appliedFixes.joined(separator: "；"))")
                    .font(.caption)
                    .foregroundStyle(Color.mimiPrimary)
                    .padding(10)
            }

            if let notice = store.codexSessionRepairNotice {
                Divider()
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(Color.mimiPrimary)
                    .padding(10)
            }

            if let error = store.lastError {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(10)
            }
        }
        .confirmationDialog(
            "修复共享运行环境？",
            isPresented: $confirmsCodexSessionRepair,
            titleVisibility: .visible
        ) {
            Button("停止服务并修复", role: .destructive) {
                Task { await store.repairSharedCodexRuntime() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请先结束所有共享的 Codex 任务和其他 Mimi 活动任务，并关闭 Codex Desktop 的 SSH 共享页面。此操作不会修改钥匙串授权或删除任务历史。检测到活动任务或其他连接时会拒绝修复。")
        }
        .task {
            await store.runDoctor(fix: false)
            await store.refreshDiagnostics()
        }
    }
}

private struct DiagnosticLogsPane: View {
    let store: HostStore
    @State private var confirmsClear = false
    @State private var exportDocument: DiagnosticLogDocument?
    @State private var presentsExporter = false
    @State private var exportError: String?

    var body: some View {
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

                    Label("仅记录在当前 Mac，不会自动上传。", systemImage: "desktopcomputer")
                        .font(.caption)
                        .foregroundStyle(.secondary)

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

            if store.recentLogs.isEmpty {
                ContentUnavailableView(
                    "暂无安全诊断日志",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("必要的失败日志会默认保留；开启详细记录可临时补充排查信息。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(store.recentLogs.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            }

            if let error = visibleError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
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
        exportDocument = DiagnosticLogDocument(lines: lines)
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

private struct DiagnosticCheckRow: View {
    let check: AgentCheck

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: check.ok ? "checkmark.circle.fill" : check.isWarning ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
                .foregroundStyle(check.ok ? Color.mimiPrimary : check.isWarning ? Color.orange : Color.red)
            VStack(alignment: .leading, spacing: 3) {
                Text(check.name)
                    .font(.headline)
                Text(check.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let fix = check.fix, !check.ok {
                    Text(fix)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
