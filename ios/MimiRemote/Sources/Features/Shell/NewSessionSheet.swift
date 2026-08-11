import SwiftUI

/// 新会话配置独立于工作台路由实现，避免主 Shell 同时承担创建表单职责。
struct NewSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("newSession.lastWorkspaceID") private var lastWorkspaceID = ""
    @AppStorage("newSession.lastRuntime") private var lastRuntimeID = WorkspaceSessionRuntimeChoice.codex.rawValue
    @State private var selectedWorkspaceID = ""
    @State private var isCreating = false
    @State private var didLeaveSheetForCreation = false
    @State private var creationErrorMessage: String?

    let onCreated: (SessionID) -> Void
    let onOpenWorkspaces: () -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        NavigationStack {
            Group {
                if sessionStore.sidebarProjects.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.text("ui.no_workspace_yet"), systemImage: "folder.badge.plus")
                    } description: {
                        Text(L10n.text("ui.first_open_a_project_directory_on_your_mac"))
                    } actions: {
                        Button(L10n.text("ui.go_to_work_area")) {
                            dismiss()
                            onOpenWorkspaces()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(tokens.primaryAction)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 26) {
                            workspaceSection(tokens: tokens)
                            runtimeSection(tokens: tokens)

                            if let creationErrorMessage {
                                Label(creationErrorMessage, systemImage: "exclamationmark.circle.fill")
                                    .font(themeStore.uiFont(.caption))
                                    .foregroundStyle(tokens.warning)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                                    .background(tokens.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .accessibilityIdentifier("newSession.creationError")
                            }
                        }
                        .frame(maxWidth: 520)
                        .padding(.horizontal, horizontalSizeClass == .compact ? 20 : 24)
                        .padding(.top, 22)
                        .padding(.bottom, 32)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .background(tokens.background)
                }
            }
            .navigationTitle(L10n.text("ui.new_session"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("ui.cancel")) { dismiss() }
                        .disabled(isCreating)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("newSession.cancel")
                }
                if !sessionStore.sidebarProjects.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            Task { await createSession() }
                        } label: {
                            if isCreating {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text(L10n.text("ui.creating"))
                                }
                            } else {
                                Text(L10n.text("ui.create"))
                            }
                        }
                        .frame(minWidth: 48)
                        .workbenchProminentActionStyle()
                        .disabled(isCreating || selectedProject == nil)
                        .tint(tokens.primaryAction)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("newSession.create")
                    }
                }
            }
        }
        .onAppear {
            synchronizeWorkspaceSelection()
            normalizeRuntimeSelection()
        }
        .onChange(of: sessionStore.sidebarProjects.map(\.id)) { _, _ in
            synchronizeWorkspaceSelection()
        }
        .onChange(of: sessionStore.hasClaudeRuntimeChannel) { _, _ in
            normalizeRuntimeSelection()
        }
        .onChange(of: sessionStore.selectedSessionID) { _, sessionID in
            guard isCreating,
                  let sessionID,
                  sessionID.hasPrefix("local:") else { return }
            leaveSheetForCreatedSession(sessionID)
        }
        // iPhone 默认用紧凑高度展示完整配置，减少大面积空白；iPad 继续交给系统 form 尺寸适配。
        .modifier(NewSessionPresentationModifier(isCompact: horizontalSizeClass == .compact))
        .interactiveDismissDisabled(isCreating)
    }

    private func workspaceSection(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                title: L10n.text("ui.workspace"),
                subtitle: L10n.text("ui.the_session_will_run_in_the_selected_directory"),
                tokens: tokens
            )

            if let project = selectedProject ?? sessionStore.sidebarProjects.first {
                Menu {
                    ForEach(sessionStore.sidebarProjects) { candidate in
                        Button {
                            // 工作区属于创建参数，选择时只更新 Sheet 本地状态，不提前切换全局会话上下文。
                            selectedWorkspaceID = candidate.id
                            creationErrorMessage = nil
                        } label: {
                            if candidate.id == selectedWorkspaceID {
                                Label(workspaceMenuTitle(for: candidate), systemImage: "checkmark")
                            } else {
                                Text(workspaceMenuTitle(for: candidate))
                            }
                        }
                    }
                } label: {
                    workspaceSummary(project, tokens: tokens)
                }
                .buttonStyle(.plain)
                .disabled(isCreating)
                .accessibilityLabel(L10n.text("ui.select_workspace"))
                .accessibilityValue(L10n.format("ui.workspace_selection_accessibility", project.name, compactWorkspacePath(project.path)))
                .accessibilityIdentifier("newSession.workspace")
            }
        }
    }

    private func runtimeSection(tokens: ThemeTokens) -> some View {
        let choices = WorkspaceSessionRuntimeChoice.available(
            claudeChannelAvailable: sessionStore.hasClaudeRuntimeChannel
        )

        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                title: L10n.text("ui.runtime"),
                subtitle: L10n.text("ui.select_the_agent_responsible_for_performing_the_task"),
                tokens: tokens
            )

            if choices.count > 1 {
                Picker(L10n.text("ui.runtime"), selection: $lastRuntimeID) {
                    ForEach(choices) { choice in
                        Text(runtimeTitle(for: choice))
                            .tag(choice.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isCreating)
                .accessibilityIdentifier("newSession.runtime")
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "terminal.fill")
                        .font(themeStore.uiFont(size: 16, weight: .semibold))
                        .foregroundStyle(tokens.primaryAction)
                        .frame(width: 36, height: 36)
                        .background(tokens.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Codex")
                            .font(themeStore.uiFont(.body, weight: .semibold))
                            .foregroundStyle(tokens.primaryText)
                        Text(L10n.text("ui.the_only_runtime_currently_available"))
                            .font(themeStore.uiFont(.caption))
                            .foregroundStyle(tokens.tertiaryText)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "checkmark.circle.fill")
                        .font(themeStore.uiFont(size: 20, weight: .semibold))
                        .foregroundStyle(tokens.primaryAction)
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(tokens.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(tokens.border.opacity(0.76), lineWidth: 1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("newSession.runtime")
            }

            Text(L10n.text("ui.cannot_be_switched_during_runtime_after_creation"))
                .font(themeStore.uiFont(.caption))
                .foregroundStyle(tokens.tertiaryText)
        }
    }

    private func sectionHeader(title: String, subtitle: String, tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(themeStore.uiFont(.headline, weight: .semibold))
                .foregroundStyle(tokens.primaryText)
            Text(subtitle)
                .font(themeStore.uiFont(.caption))
                .foregroundStyle(tokens.tertiaryText)
        }
    }

    private func workspaceSummary(_ project: AgentProject, tokens: ThemeTokens) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(themeStore.uiFont(size: 17, weight: .semibold))
                .foregroundStyle(tokens.primaryAction)
                .frame(width: 38, height: 38)
                .background(tokens.accentSoft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(themeStore.uiFont(.body, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                    .lineLimit(1)

                Text(compactWorkspacePath(project.path))
                    .font(themeStore.codeFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.up.chevron.down")
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(tokens.tertiaryText)
                .frame(width: 24, height: 24)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 70)
        .background(tokens.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(tokens.border.opacity(0.76), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func runtimeTitle(for choice: WorkspaceSessionRuntimeChoice) -> String {
        choice == .codex ? "Codex" : "Claude Code"
    }

    private func compactWorkspacePath(_ path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard path.hasPrefix("/"),
              components.count >= 2,
              components.first == "Users" else {
            return path
        }
        // 隐去本机用户名既能降低视觉噪音，也避免在远程屏幕共享时反复暴露完整绝对路径。
        let relativeComponents = components.dropFirst(2)
        return relativeComponents.isEmpty ? "~" : "~/" + relativeComponents.joined(separator: "/")
    }

    private func workspaceMenuTitle(for project: AgentProject) -> String {
        let hasDuplicateName = sessionStore.sidebarProjects.filter { $0.name == project.name }.count > 1
        guard hasDuplicateName else { return project.name }

        let components = project.path.split(separator: "/", omittingEmptySubsequences: true)
        let parentName = components.dropLast().last.map(String.init) ?? compactWorkspacePath(project.path)
        return "\(project.name) — \(parentName)"
    }

    private var selectedProject: AgentProject? {
        sessionStore.sidebarProjects.first { $0.id == selectedWorkspaceID }
    }

    private func synchronizeWorkspaceSelection() {
        let projects = sessionStore.sidebarProjects
        guard !projects.contains(where: { $0.id == selectedWorkspaceID }) else { return }

        if projects.contains(where: { $0.id == lastWorkspaceID }) {
            selectedWorkspaceID = lastWorkspaceID
        } else if let selected = sessionStore.selectedProject,
                  projects.contains(where: { $0.id == selected.id }) {
            selectedWorkspaceID = selected.id
        } else {
            selectedWorkspaceID = projects.first?.id ?? ""
        }
    }

    private func normalizeRuntimeSelection() {
        let choices = WorkspaceSessionRuntimeChoice.available(
            claudeChannelAvailable: sessionStore.hasClaudeRuntimeChannel
        )
        guard choices.contains(where: { $0.rawValue == lastRuntimeID }) else {
            lastRuntimeID = choices.first?.rawValue ?? WorkspaceSessionRuntimeChoice.codex.rawValue
            return
        }
    }

    private func createSession() async {
        guard let project = selectedProject else { return }
        isCreating = true
        creationErrorMessage = nil
        defer { isCreating = false }
        let choices = WorkspaceSessionRuntimeChoice.available(
            claudeChannelAvailable: sessionStore.hasClaudeRuntimeChannel
        )
        // 创建前再次按当前通道能力校验，避免 Sheet 打开期间通道状态变化造成错误路由。
        let choice = choices.first(where: { $0.rawValue == lastRuntimeID }) ?? .codex
        lastWorkspaceID = project.id
        await sessionStore.startNewSession(in: project, runtimeProvider: choice.runtimeProvider)
        guard let sessionID = sessionStore.selectedSessionID else {
            creationErrorMessage = sessionStore.errorMessage ?? L10n.text("ui.creation_failed_please_try_again_later")
            return
        }
        leaveSheetForCreatedSession(sessionID)
    }

    private func leaveSheetForCreatedSession(_ sessionID: SessionID) {
        guard !didLeaveSheetForCreation else { return }
        didLeaveSheetForCreation = true
        dismiss()
        onCreated(sessionID)
    }
}
