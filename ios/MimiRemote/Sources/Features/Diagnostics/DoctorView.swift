import Foundation
import SwiftUI
import UIKit

struct DoctorDiagnosticReport: Decodable, Equatable {
    let ok: Bool
    let version: String
    let listen: String
    let checks: [DoctorDiagnosticCheck]
}

struct DoctorDiagnosticCheck: Decodable, Equatable, Identifiable {
    let name: String
    let ok: Bool
    let level: String?
    let message: String
    let fix: String?

    var id: String { name }

    var displayName: String {
        switch name {
        case "token": return L10n.text("ui.access_token")
        case "projects": return L10n.text("ui.project_configuration")
        case "codex": return "Codex CLI"
        case "runtime": return "Agent Runtime"
        case "tailscale": return "Tailscale"
        case "config-file": return L10n.text("ui.profile_permissions")
        case "app-server-token-file": return L10n.text("ui.app_server_credentials_file")
        case "codex-app-server": return "Codex app-server"
        case "claude-bridge": return "Claude bridge"
        case "app-server": return "app-server gateway"
        case "app-server-upstream": return "app-server upstream"
        case "agentd-port": return L10n.text("ui.agentd_port")
        case "app-server-port": return L10n.text("ui.app_server_port")
        default: return name
        }
    }

    /// The Mac service currently returns Chinese prose. Render stable check states locally so
    /// the Doctor screen follows the app language; the raw response remains available below.
    var displayMessage: String {
        let failedKey: String
        let passedKey: String
        switch name {
        case "token":
            passedKey = "ui.doctor_access_token_ready"
            failedKey = "ui.doctor_access_token_needs_attention"
        case "projects":
            passedKey = "ui.doctor_projects_ready"
            failedKey = "ui.doctor_projects_needs_attention"
        case "codex":
            passedKey = "ui.doctor_codex_cli_ready"
            failedKey = "ui.doctor_codex_cli_needs_attention"
        case "runtime":
            passedKey = "ui.doctor_runtime_ready"
            failedKey = "ui.doctor_runtime_needs_attention"
        case "tailscale":
            passedKey = "ui.doctor_tailscale_ready"
            failedKey = "ui.doctor_tailscale_needs_attention"
        case "config-file", "app-server-token-file":
            passedKey = "ui.doctor_sensitive_file_ready"
            failedKey = "ui.doctor_sensitive_file_needs_attention"
        case "codex-app-server":
            passedKey = "ui.doctor_codex_app_server_ready"
            failedKey = "ui.doctor_codex_app_server_needs_attention"
        case "claude-bridge":
            passedKey = "ui.doctor_claude_bridge_ready"
            failedKey = "ui.doctor_claude_bridge_needs_attention"
        case "app-server", "app-server-upstream":
            passedKey = "ui.doctor_gateway_ready"
            failedKey = "ui.doctor_gateway_needs_attention"
        case "agentd-port", "app-server-port":
            passedKey = "ui.doctor_port_ready"
            failedKey = "ui.doctor_port_needs_attention"
        default:
            return L10n.text(ok ? "ui.doctor_check_passed" : (isWarning ? "ui.doctor_check_warning" : "ui.doctor_check_failed"))
        }
        return L10n.text(ok ? passedKey : failedKey)
    }

    var displayFix: String? {
        guard !ok else { return nil }
        switch name {
        case "token": return L10n.text("ui.doctor_fix_token")
        case "projects": return L10n.text("ui.doctor_fix_projects")
        case "codex": return L10n.text("ui.doctor_fix_codex")
        case "runtime": return L10n.text("ui.doctor_fix_runtime")
        case "tailscale": return L10n.text("ui.doctor_fix_tailscale")
        case "config-file", "app-server-token-file": return L10n.text("ui.doctor_fix_sensitive_file")
        case "codex-app-server": return L10n.text("ui.doctor_fix_codex_app_server")
        case "claude-bridge": return L10n.text("ui.doctor_fix_claude_bridge")
        case "app-server", "app-server-upstream": return L10n.text("ui.doctor_fix_gateway")
        case "agentd-port", "app-server-port": return L10n.text("ui.doctor_fix_port")
        default: return L10n.text("ui.doctor_fix_generic")
        }
    }

    var hasRawDiagnosticDetails: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !(fix?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var isWarning: Bool {
        !ok && level == "warning"
    }
}

struct DoctorDiagnosticDocument: Equatable {
    let report: DoctorDiagnosticReport
    let rawJSON: String
}

enum DoctorDiagnosticError: LocalizedError, Equatable {
    case invalidEndpoint
    case invalidHTTPResponse
    case httpStatus(code: Int, message: String?)
    case invalidPayload(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return L10n.text("ui.the_mac_assistant_address_is_invalid_please_return")
        case .invalidHTTPResponse:
            return L10n.text("ui.mac_assistant_returned_an_unrecognized_network_response")
        case .httpStatus(let code, let message):
            let detail = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if detail.isEmpty {
                return L10n.format("ui.diagnostic_request_failed_http_value_please_check_mac", code)
            }
            return L10n.format("ui.diagnostic_request_failed_http_value_value", code, detail)
        case .invalidPayload(let detail):
            return L10n.format("ui.the_diagnostic_result_format_cannot_be_recognized_value", detail)
        }
    }
}

enum DoctorDiagnosticsParser {
    static func doctorURL(endpoint: String) throws -> URL {
        guard var components = URLComponents(string: AgentAPIClient.normalizedEndpoint(endpoint)),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else {
            throw DoctorDiagnosticError.invalidEndpoint
        }
        components.path = "/api/doctor"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw DoctorDiagnosticError.invalidEndpoint
        }
        return url
    }

    static func parseDoctorResponse(data: Data, response: URLResponse) throws -> DoctorDiagnosticDocument {
        try validate(data: data, response: response)
        do {
            let report = try JSONDecoder().decode(DoctorDiagnosticReport.self, from: data)
            return DoctorDiagnosticDocument(
                report: report,
                rawJSON: formatDiagnosticPayload(data, fallback: L10n.text("ui.diagnosis_result_is_not_utf_8"))
            )
        } catch {
            throw DoctorDiagnosticError.invalidPayload(error.localizedDescription)
        }
    }

    static func parseRawResponse(data: Data, response: URLResponse, fallback: String) throws -> String {
        try validate(data: data, response: response)
        return formatDiagnosticPayload(data, fallback: fallback)
    }

    static func validate(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw DoctorDiagnosticError.invalidHTTPResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DoctorDiagnosticError.httpStatus(
                code: http.statusCode,
                message: serverErrorMessage(from: data)
            )
        }
    }

    static func formatDiagnosticPayload(_ data: Data, fallback: String) -> String {
        // 诊断接口默认返回紧凑 JSON；本地排序和缩进便于复制给排障人员。
        if let object = try? JSONSerialization.jsonObject(with: data),
           let prettyData = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
           ),
           let prettyText = String(data: prettyData, encoding: .utf8) {
            return prettyText
        }
        return String(data: data, encoding: .utf8) ?? fallback
    }

    private static func serverErrorMessage(from data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["message", "error"] {
                if let value = object[key] as? String,
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value
                }
                if let nested = object[key] as? [String: Any],
                   let value = nested["message"] as? String,
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value
                }
            }
        }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : String(text.prefix(500))
    }
}

private enum DoctorOperation {
    case doctor
    case history
}

private enum DoctorLoadState: Equatable {
    case idle
    case loading
    case loaded(DoctorDiagnosticDocument)
    case failed(String)
}

private enum HistoryDiagnosticLoadState: Equatable {
    case idle
    case loading
    case loaded(String)
    case failed(String)
}

struct DoctorView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var doctorState: DoctorLoadState = .idle
    @State private var historyState: HistoryDiagnosticLoadState = .idle
    @State private var activeOperation: DoctorOperation?
    @State private var isRawJSONExpanded = false
    @State private var isHistoryJSONExpanded = false

    let showsHistoryDiagnostics: Bool

    init(showsHistoryDiagnostics: Bool = false) {
        self.showsHistoryDiagnostics = showsHistoryDiagnostics
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                introduction(tokens: tokens)
                actionBar(tokens: tokens)
                doctorContent(tokens: tokens)
                if showsHistoryDiagnostics {
                    historyContent(tokens: tokens)
                }
            }
            .padding()
            .frame(maxWidth: 760, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(tokens.workbenchCanvasBackground.ignoresSafeArea())
        .navigationTitle(L10n.text("ui.diagnosis"))
        .tint(tokens.accent)
        .task {
            guard doctorState == .idle else {
                return
            }
            await runDoctor()
        }
    }

    private func introduction(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text("ui.check_the_mac_assistant_codex_cli_app_server"))
                .font(themeStore.uiFont(.callout))
                .foregroundStyle(tokens.secondaryText)
            if !showsHistoryDiagnostics {
                Text(L10n.text("ui.historical_diagnostics_are_only_displayed_after_developer_mode"))
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(tokens.secondaryText)
            }
        }
    }

    private func actionBar(tokens: ThemeTokens) -> some View {
        HStack(spacing: 10) {
            Button {
                Task { await runDoctor() }
            } label: {
                if activeOperation == .doctor {
                    Label(L10n.text("ui.under_inspection"), systemImage: "hourglass")
                } else {
                    Label(L10n.text("ui.recheck"), systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(tokens.primaryAction)
            .foregroundStyle(tokens.primaryActionForeground)
            .disabled(activeOperation != nil)
            .accessibilityHint(L10n.text("ui.request_doctor_diagnosis_results_from_mac_assistant"))

            if showsHistoryDiagnostics {
                Button {
                    Task { await runHistoryDiagnostics() }
                } label: {
                    if activeOperation == .history {
                        Label(L10n.text("ui.load_historical_diagnostics"), systemImage: "hourglass")
                    } else {
                        Label(L10n.text("ui.historical_diagnosis"), systemImage: "clock.badge.questionmark")
                    }
                }
                .buttonStyle(.bordered)
                .tint(tokens.accent)
                .disabled(activeOperation != nil)
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func doctorContent(tokens: ThemeTokens) -> some View {
        switch doctorState {
        case .idle:
            diagnosticPlaceholder(
                title: L10n.text("ui.diagnostics_have_not_been_run_yet"),
                message: L10n.text("ui.click_recheck_to_get_status_from_mac_assistant"),
                systemImage: "stethoscope",
                tokens: tokens
            )
        case .loading:
            loadingCard(tokens: tokens)
        case .failed(let message):
            errorCard(message: message, tokens: tokens)
        case .loaded(let document):
            diagnosticReport(document, tokens: tokens)
        }
    }

    private func loadingCard(tokens: ThemeTokens) -> some View {
        HStack(spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("ui.running_doctor"))
                    .font(themeStore.uiFont(.headline))
                    .foregroundStyle(tokens.primaryText)
                Text(L10n.text("ui.waiting_for_mac_assistant_to_return_check_results"))
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(tokens.secondaryText)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tokens.selectionFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func errorCard(message: String, tokens: ThemeTokens) -> some View {
        return VStack(alignment: .leading, spacing: 12) {
            Label(L10n.text("ui.diagnostic_request_failed"), systemImage: "exclamationmark.triangle.fill")
                .font(themeStore.uiFont(.headline))
                .foregroundStyle(.red)
            Text(message)
                .font(themeStore.uiFont(.callout))
                .foregroundStyle(tokens.primaryText)
                .textSelection(.enabled)
            Button {
                Task { await runDoctor() }
            } label: {
                Label(L10n.text("ui.try_again"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(activeOperation != nil)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.red.opacity(0.22), lineWidth: 1)
        }
    }

    private func diagnosticReport(_ document: DoctorDiagnosticDocument, tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            summaryCard(document.report, tokens: tokens)

            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text("ui.check_items"))
                    .font(themeStore.uiFont(.headline))
                    .foregroundStyle(tokens.primaryText)
                ForEach(document.report.checks) { check in
                    checkRow(check, tokens: tokens)
                }
            }

            rawJSONSection(
                title: L10n.text("ui.doctor_raw_json"),
                text: document.rawJSON,
                isExpanded: $isRawJSONExpanded,
                tokens: tokens
            )
        }
    }

    private func summaryCard(_ report: DoctorDiagnosticReport, tokens: ThemeTokens) -> some View {
        let warningCount = report.checks.filter(\.isWarning).count
        let hasWarnings = report.ok && warningCount > 0
        let iconName = report.ok
            ? (hasWarnings ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            : "xmark.octagon.fill"
        let statusColor: Color = report.ok
            ? (hasWarnings ? tokens.warning : .green)
            : .red

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: iconName)
                    .font(.title2)
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(report.ok ? (hasWarnings ? L10n.text("ui.service_available_reminders_available") : L10n.text("ui.service_available")) : L10n.text("ui.discover_issues_that_need_to_be_addressed"))
                        .font(themeStore.uiFont(.headline))
                        .foregroundStyle(tokens.primaryText)
                    Text(report.ok
                        ? (hasWarnings
                            ? L10n.format(
                                "ui.required_checks_passed_optional_suggestions",
                                L10n.plural("ui.optional_suggestions_count", count: warningCount)
                            )
                            : L10n.text("ui.all_necessary_checks_by_doctor_passed"))
                        : L10n.text("ui.check_out_the_suggestions_for_handling_failed_items"))
                        .font(themeStore.uiFont(.footnote))
                        .foregroundStyle(tokens.secondaryText)
                }
                Spacer(minLength: 0)
            }

            Divider()
            LabeledContent(L10n.text("ui.service_version"), value: report.version.isEmpty ? L10n.text("ui.unknown") : report.version)
            LabeledContent(L10n.text("ui.listening_address"), value: report.listen.isEmpty ? L10n.text("ui.not_configured") : report.listen)
        }
        .font(themeStore.uiFont(.callout))
        .padding(16)
        .background(tokens.selectionFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tokens.border, lineWidth: 1)
        }
    }

    private func checkRow(_ check: DoctorDiagnosticCheck, tokens: ThemeTokens) -> some View {
        let iconName = check.ok
            ? "checkmark.circle.fill"
            : (check.isWarning ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
        let statusColor: Color = check.ok ? .green : (check.isWarning ? tokens.warning : .red)
        let statusLabel = check.ok ? L10n.text("ui.passed") : (check.isWarning ? L10n.text("ui.reminder") : L10n.text("ui.failed_349c9e63"))

        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .font(.body.weight(.semibold))
                .foregroundStyle(statusColor)
                .accessibilityLabel(statusLabel)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(check.displayName)
                        .font(themeStore.uiFont(.subheadline).weight(.semibold))
                        .foregroundStyle(tokens.primaryText)
                    if check.displayName != check.name {
                        Text(check.name)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(tokens.secondaryText)
                    }
                }
                Text(check.displayMessage)
                    .font(themeStore.uiFont(.callout))
                    .foregroundStyle(tokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if !check.ok, let fix = check.displayFix {
                    Label(fix, systemImage: "wrench.and.screwdriver")
                        .font(themeStore.uiFont(.footnote))
                        .foregroundStyle(tokens.primaryText)
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .textSelection(.enabled)
                }
                if check.hasRawDiagnosticDetails {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            if !check.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                LabeledContent(L10n.text("ui.doctor_raw_message"), value: check.message)
                                    .textSelection(.enabled)
                            }
                            if let fix = check.fix?.trimmingCharacters(in: .whitespacesAndNewlines), !fix.isEmpty {
                                LabeledContent(L10n.text("ui.doctor_raw_fix"), value: fix)
                                    .textSelection(.enabled)
                            }
                        }
                        .font(themeStore.uiFont(.footnote))
                        .foregroundStyle(tokens.secondaryText)
                        .padding(.top, 2)
                    } label: {
                        Label(L10n.text("ui.mac_returned_raw_diagnostic_details"), systemImage: "doc.text.magnifyingglass")
                            .font(themeStore.uiFont(.footnote))
                            .foregroundStyle(tokens.secondaryText)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(tokens.codeBlock, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(check.ok ? tokens.border : statusColor.opacity(0.28), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func historyContent(tokens: ThemeTokens) -> some View {
        switch historyState {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text(L10n.text("ui.loading_historical_diagnostics"))
                    .foregroundStyle(tokens.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(L10n.text("ui.failed_to_load_historical_diagnostics"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Text(message)
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(tokens.secondaryText)
                    .textSelection(.enabled)
            }
        case .loaded(let text):
            rawJSONSection(
                title: L10n.text("ui.historical_diagnostic_json"),
                text: text,
                isExpanded: $isHistoryJSONExpanded,
                tokens: tokens
            )
        }
    }

    private func rawJSONSection(
        title: String,
        text: String,
        isExpanded: Binding<Bool>,
        tokens: ThemeTokens
    ) -> some View {
        DisclosureGroup(isExpanded: isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Spacer(minLength: 0)
                    Button {
                        UIPasteboard.general.string = text
                    } label: {
                        Label(L10n.text("ui.copy_original_json"), systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityHint(L10n.text("ui.copy_complete_diagnostic_content_to_clipboard"))
                }

                ScrollView(.horizontal, showsIndicators: true) {
                    Text(text)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(tokens.primaryText)
                        .lineLimit(nil)
                        .fixedSize(horizontal: true, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .padding(12)
                .background(tokens.codeBlock, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .padding(.top, 8)
        } label: {
            Label(title, systemImage: "chevron.left.forwardslash.chevron.right")
                .font(themeStore.uiFont(.subheadline).weight(.semibold))
                .foregroundStyle(tokens.primaryText)
        }
        .padding(14)
        .background(tokens.selectionFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(tokens.border, lineWidth: 1)
        }
    }

    private func diagnosticPlaceholder(
        title: String,
        message: String,
        systemImage: String,
        tokens: ThemeTokens
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        }
        .foregroundStyle(tokens.secondaryText)
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    @MainActor
    private func runDoctor() async {
        guard activeOperation == nil else {
            return
        }
        activeOperation = .doctor
        doctorState = .loading
        defer { activeOperation = nil }

        do {
            let url = try DoctorDiagnosticsParser.doctorURL(endpoint: appStore.connectionEndpoint)
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("Bearer \(appStore.token)", forHTTPHeaderField: "Authorization")
            MimiProtocolContract.applyClientHeaders(to: &request)
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            doctorState = .loaded(try DoctorDiagnosticsParser.parseDoctorResponse(data: data, response: response))
        } catch is CancellationError {
            doctorState = .idle
        } catch {
            doctorState = .failed(displayMessage(for: error))
        }
    }

    @MainActor
    private func runHistoryDiagnostics() async {
        guard activeOperation == nil else {
            return
        }
        activeOperation = .history
        historyState = .loading
        defer { activeOperation = nil }

        do {
            guard var components = URLComponents(string: AgentAPIClient.normalizedEndpoint(appStore.connectionEndpoint)) else {
                throw DoctorDiagnosticError.invalidEndpoint
            }
            components.path = "/api/debug/codex-history"
            var queryItems = [URLQueryItem(name: "limit", value: "120")]
            if let projectID = sessionStore.selectedProjectID {
                queryItems.append(URLQueryItem(name: "project_id", value: projectID))
            }
            components.queryItems = queryItems
            guard let url = components.url else {
                throw DoctorDiagnosticError.invalidEndpoint
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.setValue("Bearer \(appStore.token)", forHTTPHeaderField: "Authorization")
            MimiProtocolContract.applyClientHeaders(to: &request)
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            historyState = .loaded(try DoctorDiagnosticsParser.parseRawResponse(
                data: data,
                response: response,
                fallback: L10n.text("ui.historical_diagnostic_results_are_not_utf_8")
            ))
            isHistoryJSONExpanded = true
        } catch is CancellationError {
            historyState = .idle
        } catch {
            historyState = .failed(displayMessage(for: error))
        }
    }

    private func displayMessage(for error: Error) -> String {
        guard let urlError = error as? URLError else {
            return error.localizedDescription
        }

        switch urlError.code {
        case .notConnectedToInternet:
            return L10n.text("ui.the_device_currently_has_no_network_connection_restore")
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
            return L10n.text("ui.unable_to_connect_to_mac_assistant_please_confirm")
        case .timedOut:
            return L10n.text("ui.timeout_connecting_to_mac_assistant_please_confirm_that")
        case .userAuthenticationRequired, .userCancelledAuthentication:
            return L10n.text("ui.access_code_verification_failed_please_pair_again_in")
        default:
            // 未知 URL 错误保留稳定的中文说明和错误码，便于支持人员定位且不泄露底层英文文案。
            return L10n.format("ui.the_network_request_failed_error_code_value_please", urlError.errorCode)
        }
    }
}
