import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDiagnosticsSettingsController: ObservableObject {
    static let shared = AppDiagnosticsSettingsController()

    @Published private(set) var detailedLoggingExpiration: Date?
    @Published private(set) var isPreparingExport = false
    @Published private(set) var exportDocument: AppDiagnosticsDocument?
    @Published private(set) var operationFailed = false

    private var expirationTask: Task<Void, Never>?
    private let defaults: UserDefaults

    var isDetailedLoggingEnabled: Bool { detailedLoggingExpiration != nil }

    init(defaults: UserDefaults = .standard, now: Date = Date()) {
        self.defaults = defaults
        detailedLoggingExpiration = AppDiagnosticsPolicy.detailedLoggingExpiration(at: now, defaults: defaults)
        scheduleExpirationRefresh()
    }

    func setDetailedLoggingEnabled(_ enabled: Bool, now: Date = Date()) {
        detailedLoggingExpiration = AppDiagnosticsPolicy.setDetailedLoggingEnabled(enabled, at: now, defaults: defaults)
        if !enabled {
            AppDiagnosticTraceRegistry.shared.reset()
        }
        scheduleExpirationRefresh()
    }

    func refreshForForeground(now: Date = Date()) {
        detailedLoggingExpiration = AppDiagnosticsPolicy.detailedLoggingExpiration(at: now, defaults: defaults)
        scheduleExpirationRefresh()
        AppDiagnostics.maintain()
    }

    func prepareExport() async {
        guard !isPreparingExport else { return }
        isPreparingExport = true
        operationFailed = false
        do {
            let data = try await AppDiagnostics.exportData()
            exportDocument = AppDiagnosticsDocument(data: data)
        } catch {
            exportDocument = nil
            operationFailed = true
        }
        isPreparingExport = false
    }

    func finishExport() {
        exportDocument = nil
    }

    func clear() async {
        operationFailed = false
        do {
            try await AppDiagnostics.clear()
        } catch {
            operationFailed = true
        }
    }

    func markOperationFailed() {
        operationFailed = true
    }

    private func scheduleExpirationRefresh() {
        expirationTask?.cancel()
        guard let expiration = detailedLoggingExpiration else { return }
        expirationTask = Task { [weak self] in
            let delay = max(0, expiration.timeIntervalSinceNow)
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.detailedLoggingExpiration = AppDiagnosticsPolicy.detailedLoggingExpiration(defaults: self.defaults)
            if self.detailedLoggingExpiration == nil {
                AppDiagnosticTraceRegistry.shared.reset()
            }
        }
    }
}

struct AppDiagnosticsDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    let data: Data

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

struct AppDiagnosticsSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore
    @StateObject private var controller = AppDiagnosticsSettingsController.shared
    @State private var showsClearConfirmation = false
    @State private var presentsExporter = false

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Form {
            Section {
                Toggle(isOn: detailedLoggingBinding) {
                    SettingsValueLabel(
                        title: L10n.text("ui.temporary_detailed_logging"),
                        systemImage: "waveform.badge.magnifyingglass"
                    )
                }
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.appDiagnostics.detailedLogging")
            } header: {
                SettingsGroupHeader(showsDivider: false)
            } footer: {
                Text(detailedLoggingFooter)
                    .settingsSectionFooterStyle()
            }
            .settingsGroupRowStyle()

            Section {
                Button {
                    Task {
                        await controller.prepareExport()
                        presentsExporter = controller.exportDocument != nil
                    }
                } label: {
                    SettingsValueLabel(
                        title: L10n.text("ui.export_app_diagnostics"),
                        systemImage: "square.and.arrow.up"
                    )
                }
                .settingsStandardListRow()
                .disabled(controller.isPreparingExport)
                .accessibilityIdentifier("settings.appDiagnostics.export")

                Button(role: .destructive) {
                    showsClearConfirmation = true
                } label: {
                    SettingsValueLabel(
                        title: L10n.text("ui.clear_app_diagnostics"),
                        systemImage: "trash"
                    )
                }
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.appDiagnostics.clear")
            } header: {
                SettingsGroupHeader()
            } footer: {
                Text(L10n.text("ui.app_diagnostics_storage_explanation"))
                    .settingsSectionFooterStyle()
            }
            .settingsGroupRowStyle()

            if controller.operationFailed {
                Section {
                    Label(L10n.text("ui.app_diagnostics_operation_failed"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(tokens.warning)
                        .settingsStandardListRow()
                } header: {
                    SettingsGroupHeader()
                }
                .settingsGroupRowStyle()
            }
        }
        .themedSettingsForm(tokens: tokens)
        .settingsDetailPage()
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(L10n.text("ui.app_diagnostics"))
        .confirmationDialog(
            L10n.text("ui.clear_app_diagnostics_confirmation"),
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("ui.clear_app_diagnostics"), role: .destructive) {
                Task { await controller.clear() }
            }
            Button(L10n.text("ui.cancel"), role: .cancel) {}
        }
        .fileExporter(
            isPresented: $presentsExporter,
            document: controller.exportDocument,
            contentType: .plainText,
            defaultFilename: "MimiRemote-Diagnostics.jsonl"
        ) { result in
            if case .failure = result {
                controller.markOperationFailed()
            }
            controller.finishExport()
        }
        .onAppear {
            controller.refreshForForeground()
        }
    }

    private var detailedLoggingBinding: Binding<Bool> {
        Binding(
            get: { controller.isDetailedLoggingEnabled },
            set: { controller.setDetailedLoggingEnabled($0) }
        )
    }

    private var detailedLoggingFooter: String {
        guard let expiration = controller.detailedLoggingExpiration else {
            return L10n.text("ui.detailed_logging_off_explanation")
        }
        return L10n.format(
            "ui.detailed_logging_expiration_value",
            expiration.formatted(date: .omitted, time: .shortened)
        )
    }
}
