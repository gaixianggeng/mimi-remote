import SwiftUI

// Worktree 管理流程独立于项目与会话列表，降低侧边栏主体的更新和维护范围。
struct WorktreeManagerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    let rootProjectID: String
    @State private var pendingDelete: WorktreeListItem?
    @State private var cleanupDestination: WorktreeCleanupDestination?
    @State private var isLoadingCleanupPreview = false
    @State private var cleanupPreviewError: String?

    private var worktrees: [WorktreeListItem] {
        sessionStore.managedWorktrees(rootProjectID: rootProjectID)
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        NavigationStack {
            List {
                if let message = sessionStore.worktreeErrorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(themeStore.uiFont(.footnote, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    ForEach(worktrees) { item in
                        WorktreeManagerRow(
                            item: item,
                            isRunning: sessionStore.hasRunningSession(in: item),
                            isBusy: sessionStore.isDeletingWorktree,
                            onOpen: {
                                Task {
                                    _ = await sessionStore.openManagedWorktree(item)
                                    dismiss()
                                }
                            },
                            onDelete: {
                                pendingDelete = item
                            }
                        )
                    }
                }
                Section {
                    Button {
                        Task { await loadCleanupPreview() }
                    } label: {
                        if isLoadingCleanupPreview {
                            Label(L10n.text("ui.evaluating_cleanup_candidates"), systemImage: "hourglass")
                        } else {
                            Label(L10n.text("ui.cleanup_candidates"), systemImage: "sparkles")
                        }
                    }
                    .disabled(sessionStore.isRefreshingWorktrees || sessionStore.isDeletingWorktree || sessionStore.isPruningWorktrees || isLoadingCleanupPreview)

                    Button {
                        Task { await sessionStore.pruneMissingManagedWorktrees() }
                    } label: {
                        if sessionStore.isPruningWorktrees {
                            Label(L10n.text("ui.cleaning_up"), systemImage: "hourglass")
                        } else {
                            Label(L10n.text("ui.clear_lost_registration"), systemImage: "checklist.unchecked")
                        }
                    }
                    .disabled(sessionStore.isRefreshingWorktrees || sessionStore.isDeletingWorktree || sessionStore.isPruningWorktrees)

                    if let cleanupPreviewError {
                        Label(cleanupPreviewError, systemImage: "exclamationmark.triangle.fill")
                            .font(themeStore.uiFont(.footnote, weight: .medium))
                            .foregroundStyle(.red)
                    }
                } footer: {
                    Text(L10n.text("ui.clean_candidates_will_first_be_previewed_according_to"))
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.text("ui.git_worktree"))
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(tokens.background)
            .overlay {
                if worktrees.isEmpty && !sessionStore.isRefreshingWorktrees {
                    ContentUnavailableView(
                        L10n.text("ui.no_git_worktree"),
                        systemImage: "square.stack.3d.up",
                        description: Text(L10n.text("ui.there_are_no_managed_git_worktrees_for_the"))
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("ui.close")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await sessionStore.refreshManagedWorktrees() }
                    } label: {
                        if sessionStore.isRefreshingWorktrees {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(sessionStore.isRefreshingWorktrees || sessionStore.isPruningWorktrees)
                    .accessibilityLabel(L10n.text("ui.refresh_git_worktree"))
                }
            }
        }
        .task {
            await sessionStore.refreshManagedWorktrees()
        }
        .sheet(item: $cleanupDestination) { destination in
            WorktreeCleanupPreviewSheet(
                preview: destination.preview,
                rootProjectID: rootProjectID
            )
        }
        .confirmationDialog(L10n.text("ui.delete_git_worktree"), isPresented: Binding(
            get: { pendingDelete != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDelete = nil
                }
            }
        ), titleVisibility: .visible) {
            if let item = pendingDelete {
                Button(L10n.format("ui.delete_value", item.workspace.name), role: .destructive) {
                    let target = item
                    pendingDelete = nil
                    Task { await sessionStore.deleteManagedWorktree(target, force: false) }
                }
            }
            Button(L10n.text("ui.cancel"), role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            Text(L10n.text("ui.deletions_will_still_be_checked_by_agentd_against"))
        }
    }

    @MainActor
    private func loadCleanupPreview() async {
        guard !isLoadingCleanupPreview else {
            return
        }
        isLoadingCleanupPreview = true
        cleanupPreviewError = nil
        defer { isLoadingCleanupPreview = false }
        do {
            let preview = try await sessionStore.previewManagedWorktreeCleanup()
            cleanupDestination = WorktreeCleanupDestination(preview: preview)
        } catch {
            cleanupPreviewError = userFacingCleanupError(error)
        }
    }

    private func userFacingCleanupError(_ error: Error) -> String {
        if case AgentAPIError.server(let status, _) = error, status == 404 || status == 405 {
            return L10n.text("ui.the_current_agentd_version_does_not_support_clean")
        }
        return error.localizedDescription
    }
}

struct WorktreeCleanupDestination: Identifiable {
    let id = UUID()
    let preview: WorktreeCleanupResponse
}

struct WorktreeCleanupPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore

    @State private var preview: WorktreeCleanupResponse
    @State private var selectedPaths: Set<String>
    @State private var isExecuting = false
    @State private var isShowingDestructiveConfirmation = false
    @State private var executionError: String?
    let rootProjectID: String

    init(preview: WorktreeCleanupResponse, rootProjectID: String) {
        self.rootProjectID = rootProjectID
        _preview = State(initialValue: preview)
        let candidates = Set(preview.candidatePaths)
        _selectedPaths = State(initialValue: Set(preview.worktrees.compactMap { item in
            let root = item.workspace.rootProjectID ?? item.worktree.rootProjectID
            guard root == rootProjectID,
                  item.eligible,
                  candidates.contains(item.worktree.path)
            else {
                return nil
            }
            return item.worktree.path
        }))
    }

    private var projectItems: [WorktreeCleanupItem] {
        preview.worktrees.filter { item in
            (item.workspace.rootProjectID ?? item.worktree.rootProjectID) == rootProjectID
        }
    }

    private var candidatePaths: Set<String> {
        Set(preview.candidatePaths)
    }

    private var isPlanExecutable: Bool {
        // 只有 dry-run 响应里的 plan_id 可以执行一次。执行响应即使还带着旧候选，
        // 也只能用于展示结果，不能再次选择并提交已经消费的计划。
        preview.dryRun && !preview.hasPartialFailure
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        NavigationStack {
            List {
                Section(L10n.text("ui.retention_policy")) {
                    LabeledContent(L10n.text("ui.automatically_delete"), value: preview.policy.autoDelete ? L10n.text("ui.turn_on") : L10n.text("ui.close"))
                    LabeledContent(L10n.text("ui.candidate_time"), value: L10n.plural("ui.days_unused_count", count: preview.policy.candidateAfterDays))
                    LabeledContent(L10n.text("ui.each_project_retains_at_least"), value: L10n.format("ui.recent_value", preview.policy.keepLatestPerProject))
                    LabeledContent(L10n.text("ui.assessment_time"), value: preview.generatedAt.formatted(date: .abbreviated, time: .shortened))
                }

                Section {
                    if projectItems.isEmpty {
                        ContentUnavailableView(
                            L10n.text("ui.no_evaluable_worktree"),
                            systemImage: "checkmark.shield",
                            description: Text(L10n.text("ui.the_current_project_has_no_managed_worktrees_that"))
                        )
                    } else {
                        ForEach(projectItems) { item in
                            WorktreeCleanupPreviewRow(
                                item: item,
                                isCandidate: isPlanExecutable && candidatePaths.contains(item.worktree.path),
                                isSelected: selectedPaths.contains(item.worktree.path),
                                isBusy: isExecuting
                            ) {
                                toggleSelection(item)
                            }
                        }
                    }
                } header: {
                    Text(L10n.text("ui.candidates_and_conservation_reasons"))
                } footer: {
                    Text(L10n.text("ui.only_paths_that_are_dry_run_on_the"))
                }

                if let executionError {
                    Section(L10n.text("ui.clean_results")) {
                        Label(executionError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        isShowingDestructiveConfirmation = true
                    } label: {
                        if isExecuting {
                            Label(L10n.text("ui.rechecking_and_cleaning"), systemImage: "hourglass")
                        } else {
                            Label(L10n.plural("ui.worktrees_to_delete_count", count: selectedPaths.count), systemImage: "trash")
                        }
                    }
                    .disabled(selectedPaths.isEmpty || isExecuting)
                } footer: {
                    Text(L10n.text("ui.agentd_will_recalculate_the_blocker_when_executed_policy"))
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(tokens.background)
            .navigationTitle(L10n.text("ui.clean_up_worktree"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("ui.close")) { dismiss() }
                        .disabled(isExecuting)
                }
            }
        }
        .confirmationDialog(
            L10n.plural("ui.confirm_delete_worktrees_count", count: selectedPaths.count),
            isPresented: $isShowingDestructiveConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("ui.confirm_deletion"), role: .destructive) {
                Task { await executeCleanup() }
            }
            Button(L10n.text("ui.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("ui.this_will_delete_the_corresponding_git_checkout_the"))
        }
    }

    private func toggleSelection(_ item: WorktreeCleanupItem) {
        guard isPlanExecutable,
              item.eligible,
              candidatePaths.contains(item.worktree.path),
              !isExecuting
        else {
            return
        }
        if selectedPaths.contains(item.worktree.path) {
            selectedPaths.remove(item.worktree.path)
        } else {
            selectedPaths.insert(item.worktree.path)
        }
        executionError = nil
    }

    @MainActor
    private func executeCleanup() async {
        guard !isExecuting else {
            return
        }
        isExecuting = true
        executionError = nil
        defer { isExecuting = false }
        do {
            let response = try await sessionStore.cleanupManagedWorktrees(paths: selectedPaths, preview: preview)
            if let partialFailureMessage = response.partialFailureMessage {
                // plan_id 在执行开始后即失效；部分成功时保留结果页，但清空选择，
                // 要求用户关闭后重新 dry-run，不能误用旧计划重试剩余路径。
                preview = response
                selectedPaths = []
                executionError = partialFailureMessage
                return
            }
            guard !response.deletedPaths.isEmpty else {
                preview = response
                selectedPaths = []
                executionError = L10n.text("ui.agentd_did_not_delete_any_worktree_after_rechecking")
                return
            }
            dismiss()
        } catch {
            executionError = error.localizedDescription
        }
    }
}

struct WorktreeCleanupPreviewRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore
    let item: WorktreeCleanupItem
    let isCandidate: Bool
    let isSelected: Bool
    let isBusy: Bool
    let onToggle: () -> Void

    private var isSelectable: Bool {
        item.eligible && isCandidate
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelectable ? (isSelected ? "checkmark.circle.fill" : "circle") : "lock.shield.fill")
                    .foregroundStyle(isSelectable ? tokens.accent : tokens.secondaryText)
                    .font(themeStore.uiFont(.title3, weight: .semibold))
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 6) {
                    Text(item.workspace.name)
                        .font(themeStore.uiFont(.subheadline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                    Text(item.worktree.path)
                        .font(themeStore.uiFont(.caption2))
                        .foregroundStyle(tokens.tertiaryText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    cleanupDates
                    if isSelectable {
                        Label(L10n.text("ui.comply_with_cleanup_strategy"), systemImage: "checkmark.shield")
                            .font(themeStore.uiFont(.caption, weight: .medium))
                            .foregroundStyle(tokens.success)
                    } else {
                        blockers
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isSelectable || isBusy)
        .accessibilityLabel(accessibilityLabel)
    }

    private var cleanupDates: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let createdAt = item.createdAt {
                Text(L10n.format("ui.create_value", createdAt.formatted(date: .abbreviated, time: .omitted)))
            }
            if let lastUsedAt = item.lastUsedAt {
                Text(L10n.format("ui.recently_used_value", lastUsedAt.formatted(date: .abbreviated, time: .shortened)))
            }
        }
        .font(themeStore.uiFont(.caption2))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var blockers: some View {
        if item.blockers.isEmpty {
            Label(L10n.text("ui.the_server_is_not_determined_to_be_cleanable"), systemImage: "shield")
                .font(themeStore.uiFont(.caption, weight: .medium))
                .foregroundStyle(.orange)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(item.blockers) { blocker in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(blocker.message)
                            .font(themeStore.uiFont(.caption, weight: .medium))
                            .foregroundStyle(.orange)
                        // 10 提到 caption2（11），并改走 codeFont：这一列是机器码，等宽对齐不能丢。
                        Text(blocker.code)
                            .font(themeStore.codeFont(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var accessibilityLabel: String {
        if isSelectable {
            return L10n.format("ui.value_cleanable_value", item.workspace.name, isSelected ? L10n.text("ui.selected") : L10n.text("ui.not_selected"))
        }
        let reasons = item.blockers.map(\.message).joined(separator: L10n.text("ui.list_separator"))
        return L10n.format("ui.value_cannot_be_cleaned_value", item.workspace.name, reasons)
    }
}

struct CreateWorktreeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    let project: AgentProject
    @State private var name = ""
    @State private var base = ""
    @State private var branch = ""
    @State private var didApplyDefaultBase = false

    private var canCreate: Bool {
        !sessionStore.isCreatingWorktree
    }

    private var branchList: WorktreeBranchListResponse? {
        sessionStore.worktreeBranches(path: project.path)
    }

    private var baseBranchItems: [WorktreeBranchItem] {
        branchList?.branches ?? []
    }

    private var branchErrorMessage: String? {
        sessionStore.worktreeBranchError(path: project.path)
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        NavigationStack {
            Form {
                Section {
                    LabeledContent(L10n.text("ui.project")) {
                        Text(project.name)
                            .foregroundStyle(tokens.secondaryText)
                            .lineLimit(1)
                    }
                    TextField(L10n.text("ui.name"), text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack(spacing: 8) {
                        TextField(L10n.text("ui.base_branch"), text: $base)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if sessionStore.isRefreshingWorktreeBranches && baseBranchItems.isEmpty {
                            ProgressView()
                                .controlSize(.small)
                        } else if !baseBranchItems.isEmpty {
                            Menu {
                                ForEach(baseBranchItems) { item in
                                    Button {
                                        base = item.name
                                        didApplyDefaultBase = true
                                    } label: {
                                        Label(branchMenuTitle(item), systemImage: branchIconName(item))
                                    }
                                }
                            } label: {
                                Image(systemName: "list.bullet")
                                    .foregroundStyle(tokens.secondaryText)
                                    .frame(width: 28, height: 28)
                            }
                            .accessibilityLabel(L10n.text("ui.select_base"))
                        }
                    }
                    TextField(L10n.text("ui.branch"), text: $branch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if let message = branchErrorMessage, !message.isEmpty {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(themeStore.uiFont(.footnote, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }

                if let message = sessionStore.errorMessage, !message.isEmpty {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(themeStore.uiFont(.footnote, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(tokens.background)
            .navigationTitle(L10n.text("ui.create_a_new_git_worktree"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("ui.cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            let opened = await sessionStore.createWorktreeAndOpen(
                                project: project,
                                name: normalizedOptional(name),
                                base: normalizedOptional(base),
                                branch: normalizedOptional(branch)
                            )
                            if opened {
                                dismiss()
                            }
                        }
                    } label: {
                        if sessionStore.isCreatingWorktree {
                            ProgressView()
                        } else {
                            Text(L10n.text("ui.create"))
                        }
                    }
                    .disabled(!canCreate)
                }
            }
            .task(id: project.path) {
                await sessionStore.refreshWorktreeBranches(path: project.path)
                applyDefaultBaseIfNeeded()
            }
            .onChange(of: branchList?.defaultBase ?? "") { _, _ in
                applyDefaultBaseIfNeeded()
            }
        }
    }

    private func normalizedOptional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func applyDefaultBaseIfNeeded() {
        guard !didApplyDefaultBase,
              normalizedOptional(base) == nil,
              let defaultBase = branchList?.defaultBase,
              !defaultBase.isEmpty
        else {
            return
        }
        base = defaultBase
        didApplyDefaultBase = true
    }

    private func branchMenuTitle(_ item: WorktreeBranchItem) -> String {
        if item.isCurrent {
            return L10n.format("ui.value_current", item.name)
        }
        if item.isDefault {
            return L10n.format("ui.value_default", item.name)
        }
        return item.name
    }

    private func branchIconName(_ item: WorktreeBranchItem) -> String {
        item.kind == "remote" ? "arrow.down.circle" : "point.topleft.down.curvedto.point.bottomright.up"
    }
}

struct WorktreeManagerRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore
    let item: WorktreeListItem
    let isRunning: Bool
    let isBusy: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(tokens.accent)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.workspace.name)
                        .font(themeStore.uiFont(.subheadline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                        .lineLimit(1)
                    Text(item.worktree.rootProjectName)
                        .font(themeStore.uiFont(.caption, weight: .medium))
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if isRunning {
                    Text(L10n.text("ui.running"))
                        .font(themeStore.uiFont(.caption2, weight: .semibold))
                        .foregroundStyle(tokens.primaryAction)
                }
            }

            Text(item.workspace.path)
                .font(themeStore.uiFont(.caption, weight: .regular))
                .foregroundStyle(tokens.tertiaryText)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(item.worktree.branch ?? item.worktree.base, systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                        .font(themeStore.uiFont(.caption2, weight: .medium))
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(1)
                    Label(L10n.format("ui.base_named", item.worktree.base), systemImage: "arrow.triangle.branch")
                        .font(themeStore.uiFont(.caption2, weight: .regular))
                        .foregroundStyle(tokens.tertiaryText)
                        .lineLimit(1)
                }
                Spacer()
                Button(action: onOpen) {
                    Label(L10n.text("ui.open"), systemImage: "arrow.up.forward.square")
                }
                .buttonStyle(.borderless)
                Button(role: .destructive, action: onDelete) {
                    Label(L10n.text("ui.delete"), systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(isRunning || isBusy)
            }

            if !worktreeStatusItems.isEmpty {
                HStack(spacing: 6) {
                    ForEach(worktreeStatusItems, id: \.self) { item in
                        Text(item)
                            .font(themeStore.uiFont(.caption2, weight: .semibold))
                            .foregroundStyle(tokens.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(tokens.surface, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var worktreeStatusItems: [String] {
        var items: [String] = []
        if item.worktree.gitState == "unknown" {
            items.append(L10n.text("ui.git_status_unknown"))
        } else if item.worktree.dirty || item.worktree.gitState == "dirty" {
            items.append(L10n.text("ui.not_submitted"))
        }
        if item.worktree.ahead > 0 {
            items.append(L10n.format("ui.leading_value", item.worktree.ahead))
        }
        if item.worktree.behind > 0 {
            items.append(L10n.format("ui.behind_value", item.worktree.behind))
        }
        if let upstream = item.worktree.upstream?.trimmingCharacters(in: .whitespacesAndNewlines), !upstream.isEmpty {
            items.append(upstream)
        }
        return items
    }
}

struct SidebarListRowStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

extension View {
    func sidebarListRow() -> some View {
        modifier(SidebarListRowStyle())
    }
}
