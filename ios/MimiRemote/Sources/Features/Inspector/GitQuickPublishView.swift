import SwiftUI

enum GitCommitMessageSuggestion {
    static func make(from status: GitStatusResponse) -> String {
        let paths = status.files.map { $0.path.lowercased() }
        guard !paths.isEmpty else {
            return L10n.text("ui.chore_synchronize_the_current_branch")
        }

        if paths.allSatisfy({ $0.hasSuffix(".md") || $0.hasPrefix("docs/") }) {
            return L10n.text("ui.docs_update_project_documentation")
        }
        if paths.allSatisfy(isTestPath) {
            return L10n.text("ui.test_update_automated_tests")
        }
        if paths.allSatisfy(isReleasePath) {
            return L10n.text("ui.chore_update_release_process")
        }

        let type = status.files.contains(where: isAddedFile) ? "feat" : "chore"
        return L10n.format("ui.value_update_value", type, scopeName(for: paths))
    }

    private static func isTestPath(_ path: String) -> Bool {
        path.contains("/tests/")
            || path.hasPrefix("tests/")
            || path.hasSuffix("_test.go")
            || path.hasSuffix("tests.swift")
    }

    private static func isReleasePath(_ path: String) -> Bool {
        path.hasPrefix("scripts/")
            || path.hasPrefix(".github/")
            || path.hasPrefix("config/release/")
    }

    private static func isAddedFile(_ file: GitFileStatus) -> Bool {
        file.untracked || file.code.contains("A") || file.code == "??"
    }

    private static func scopeName(for paths: [String]) -> String {
        if paths.allSatisfy({ $0.hasPrefix("ios/") }) {
            if paths.contains(where: { $0.contains("/conversation/") }) {
                return L10n.text("ui.conversational_interaction")
            }
            if paths.contains(where: { $0.contains("/inspector/") }) {
                return L10n.text("ui.git_change_panel")
            }
            if paths.contains(where: { $0.contains("/state/") }) {
                return L10n.text("ui.ios_state_management")
            }
            return L10n.text("ui.ios_client")
        }
        if paths.allSatisfy({ $0.hasPrefix("internal/") || $0.hasPrefix("cmd/") }) {
            return L10n.text("ui.hosting_service")
        }
        if paths.allSatisfy({ $0.hasPrefix("scripts/") || $0.hasPrefix("config/") }) {
            return L10n.text("ui.project_tools")
        }
        return L10n.text("ui.project_changes")
    }
}

struct GitQuickPublishBox: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    @Binding var message: String
    let status: GitStatusResponse
    let testFlightStatus: GitTestFlightStatusResponse?
    let testFlightError: String?
    let isWorking: Bool
    let isRefreshingTestFlight: Bool
    let onRegenerateMessage: () -> Void
    let onQuickPublish: () -> Void
    let onTestFlight: () -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 10) {
            header(tokens: tokens)
            repositoryState(tokens: tokens)
            if let synchronizationWarning {
                Label(synchronizationWarning, systemImage: "exclamationmark.triangle.fill")
                    .font(themeStore.uiFont(.caption2, weight: .semibold))
                    .foregroundStyle(tokens.warning)
            }

            if status.hasChanges {
                commitMessageField(tokens: tokens)
            }

            publishButton(tokens: tokens)

            if shouldShowTestFlight {
                testFlightButton(tokens: tokens)
                Text(testFlightCaption)
                    .font(themeStore.uiFont(.caption2))
                    .foregroundStyle(testFlightCaptionTint(tokens: tokens))
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if isRefreshingTestFlight {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.text("ui.checking_host_publishing_capabilities"))
                }
                .font(themeStore.uiFont(.caption2))
                .foregroundStyle(tokens.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
            }

            if let job = testFlightStatus?.job {
                releaseJobStatus(job, tokens: tokens)
            }
            if let testFlightError, !testFlightError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label(testFlightError, systemImage: "exclamationmark.triangle")
                    .font(themeStore.uiFont(.caption2))
                    .foregroundStyle(tokens.warning)
                    .lineLimit(4)
            }

            Label(L10n.text("ui.it_will_be_confirmed_again_before_execution_and"), systemImage: "shield.lefthalf.filled")
                .font(themeStore.uiFont(.caption2))
                .foregroundStyle(tokens.tertiaryText)
        }
        .padding(12)
        .background(tokens.elevatedSurface.opacity(0.92), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tokens.accent.opacity(0.24), lineWidth: 1)
        }
    }

    private var releaseJob: GitTestFlightJob? {
        testFlightStatus?.job
    }

    private var releaseIsRunning: Bool {
        releaseJob?.isRunning == true
    }

    private var canQuickPublish: Bool {
        !isWorking
            && !releaseIsRunning
            && !(status.branch?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && (!status.hasChanges || !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && (status.behind ?? 0) == 0
    }

    private var shouldShowTestFlight: Bool {
        testFlightStatus?.capability.isIOSProject == true || releaseJob != nil
    }

    private var canPublishTestFlight: Bool {
        testFlightStatus?.capability.available == true
            && !status.hasChanges
            && !isWorking
            && !releaseIsRunning
    }

    private var testFlightCaption: String {
        if releaseIsRunning {
            return L10n.text("ui.the_host_is_archiving_and_uploading_you_can")
        }
        if status.hasChanges {
            return L10n.text("ui.available_after_successful_push_submission")
        }
        return testFlightStatus?.capability.reason ?? L10n.text("ui.the_host_is_not_configured_with_the_testflight")
    }

    @ViewBuilder
    private func header(tokens: ThemeTokens) -> some View {
        HStack(spacing: 8) {
            Label(L10n.text("ui.quick_release"), systemImage: "wand.and.sparkles")
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(tokens.primaryText)
            if testFlightStatus?.capability.isIOSProject == true {
                Text(L10n.text("ui.ios_project"))
                    .font(themeStore.uiFont(.caption2, weight: .semibold))
                    .foregroundStyle(tokens.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(tokens.accent.opacity(0.12), in: Capsule())
            }
            Spacer()
            if isWorking || isRefreshingTestFlight {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func repositoryState(tokens: ThemeTokens) -> some View {
        HStack(spacing: 9) {
            Image(
                systemName: (status.behind ?? 0) > 0
                    ? "exclamationmark.triangle.fill"
                    : (status.hasChanges ? "checkmark.circle" : "checkmark.circle.fill")
            )
                .font(themeStore.uiFont(size: 18, weight: .semibold))
                .foregroundStyle(
                    (status.behind ?? 0) > 0
                        ? tokens.warning
                        : (status.hasChanges ? tokens.accent : tokens.success)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(status.hasChanges ? L10n.plural("ui.files_to_commit_count", count: status.files.count) : L10n.text("ui.workspace_submitted"))
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                Text("\(displayBranch) → \(publishTarget)")
                    .font(themeStore.codeFont(.caption2))
                    .foregroundStyle(tokens.secondaryText)
            }
        }
    }

    private var displayBranch: String {
        let branch = status.branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return branch.isEmpty ? L10n.text("ui.current_branch") : branch
    }

    private var publishTarget: String {
        let upstream = status.upstream?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return upstream.isEmpty ? "origin/\(displayBranch)" : upstream
    }

    private var synchronizationWarning: String? {
        let ahead = status.ahead ?? 0
        let behind = status.behind ?? 0
        if ahead > 0, behind > 0 {
            return L10n.text("ui.git_branch_diverged")
        }
        if behind > 0 {
            return L10n.format("ui.behind_value", behind)
        }
        return nil
    }

    @ViewBuilder
    private func commitMessageField(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.text("ui.submission_instructions"))
                .font(themeStore.uiFont(.caption2))
                .foregroundStyle(tokens.tertiaryText)
            HStack(spacing: 6) {
                TextField(L10n.text("ui.submission_instructions"), text: $message, axis: .vertical)
                    .font(themeStore.uiFont(.caption))
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)
                    .padding(.horizontal, 9)
                    .frame(minHeight: 40)
                Button(action: onRegenerateMessage) {
                    Label(L10n.text("ui.regenerate_commit_instructions"), systemImage: "wand.and.sparkles")
                        .labelStyle(.iconOnly)
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(tokens.accent)
                .help(L10n.text("ui.regenerate_commit_instructions_based_on_current_file"))
            }
            .background(tokens.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(tokens.border, lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private func publishButton(tokens: ThemeTokens) -> some View {
        Button(action: onQuickPublish) {
            HStack(spacing: 8) {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.up.circle")
                }
                Text(status.hasChanges ? L10n.text("ui.submit_and_push") : L10n.text("ui.push_current_branch"))
            }
            .font(themeStore.uiFont(.caption, weight: .semibold))
            .foregroundStyle(canQuickPublish ? Color.white : tokens.tertiaryText)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(canQuickPublish ? tokens.accent : tokens.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canQuickPublish)
        .accessibilityHint(L10n.text("ui.temporarily_save_changes_to_the_current_workspace_and"))
    }

    @ViewBuilder
    private func testFlightButton(tokens: ThemeTokens) -> some View {
        Button(action: onTestFlight) {
            HStack(spacing: 8) {
                if releaseIsRunning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "paperplane")
                }
                Text(releaseIsRunning ? L10n.text("ui.publishing_testflight") : L10n.text("ui.publish_testflight"))
            }
            .font(themeStore.uiFont(.caption, weight: .semibold))
            .foregroundStyle(canPublishTestFlight ? tokens.primaryText : tokens.tertiaryText)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(tokens.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(canPublishTestFlight ? tokens.secondaryText : tokens.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!canPublishTestFlight)
        .accessibilityHint(L10n.text("ui.execute_a_configured_and_preflighted_local_testflight_publishing"))
    }

    @ViewBuilder
    private func releaseJobStatus(_ job: GitTestFlightJob, tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(releaseJobTitle(job), systemImage: releaseJobSymbol(job))
                .font(themeStore.uiFont(.caption2, weight: .semibold))
                .foregroundStyle(releaseJobTint(job, tokens: tokens))
            if let output = job.output?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
                Text(output)
                    .font(themeStore.codeFont(.caption2))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tokens.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func releaseJobTitle(_ job: GitTestFlightJob) -> String {
        switch job.state {
        case "running": return L10n.text("ui.testflight_release_in_progress")
        case "succeeded": return L10n.text("ui.testflight_release_completed")
        default: return L10n.text("ui.testflight_publishing_failed")
        }
    }

    private func releaseJobSymbol(_ job: GitTestFlightJob) -> String {
        switch job.state {
        case "running": return "clock.arrow.circlepath"
        case "succeeded": return "checkmark.circle.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }

    private func releaseJobTint(_ job: GitTestFlightJob, tokens: ThemeTokens) -> Color {
        switch job.state {
        case "running": tokens.accent
        case "succeeded": tokens.success
        default: tokens.warning
        }
    }

    private func testFlightCaptionTint(tokens: ThemeTokens) -> Color {
        if releaseJob?.succeeded == true {
            return tokens.success
        }
        if testFlightStatus?.capability.available == false && !status.hasChanges {
            return tokens.warning
        }
        return tokens.tertiaryText
    }
}
