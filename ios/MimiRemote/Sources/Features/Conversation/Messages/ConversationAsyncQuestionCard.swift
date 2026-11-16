import SwiftUI

struct ConversationAsyncQuestionCard: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var conversationStore: ConversationStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let message: ConversationMessage
    let layout: ConversationLayout
    let sessionID: SessionID?
    @State private var stepIndex = 0
    @State private var draft = PendingUserInputDraft()
    @FocusState private var focusedQuestionID: String?

    var body: some View {
        if let question = message.activityPayload?.asyncQuestion, let sessionID,
           let session = sessionStore.sessionsByID[sessionID] {
            let progress = CodexAsyncQuestionProgress.make(
                question: question, message: message, messages: conversationStore.messages(for: sessionID)
            )
            let isSubmitting = progress.isSubmitting || sessionStore.isAnsweringAsyncQuestion(question, sessionID: sessionID)
            let isResolved = progress.isResolved(question)
            let canAnswer = sessionStore.canAnswerAsyncQuestion(message, sessionID: sessionID) && !isSubmitting
            let request = question.request(sessionID: sessionID, turnID: message.turnID, answeredIndices: progress.answeredIndices)
            let runtimePresentation = SessionRuntimePresentation(session: session)
            let tokens = themeStore.tokens(for: colorScheme)
            let totalSteps = max(1, request.questions.count)
            let clampedStep = min(max(stepIndex, 0), totalSteps - 1)

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 8) {
                    Label(L10n.text("ui.async_question_title"), systemImage: "questionmark.bubble")
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                        .foregroundStyle(tokens.secondaryText)
                    Spacer(minLength: 0)
                    if !progress.isExpired && !isResolved {
                        AgentQuestionStepPager(
                            stepIndex: $stepIndex,
                            totalSteps: request.questions.count,
                            onStepWillChange: { focusedQuestionID = nil }
                        )
                    }
                    AgentRequestRuntimeIcon(presentation: runtimePresentation, size: 26)
                }

                if progress.isExpired {
                    questionTitlesSummary(question: question, progress: progress, tokens: tokens)
                    Text(L10n.text("ui.supplemental_information_request_expired"))
                        .font(themeStore.uiFont(.subheadline))
                        .foregroundStyle(tokens.secondaryText)
                } else if isResolved {
                    questionTitlesSummary(question: question, progress: progress, tokens: tokens)
                    Label(L10n.text("ui.async_question_answered"), systemImage: "checkmark.circle.fill")
                        .font(themeStore.uiFont(.caption, weight: .medium))
                        .foregroundStyle(tokens.secondaryText)
                } else {
                    AgentQuestionStepBody(
                        request: request,
                        stepIndex: clampedStep,
                        isDisabled: !canAnswer,
                        draft: $draft,
                        focusedQuestionID: $focusedQuestionID,
                        onPrimaryStepAction: {
                            guard canAnswer else { return }
                            if clampedStep >= totalSteps - 1 {
                                focusedQuestionID = nil
                                _ = sessionStore.answerAsyncQuestion(
                                    message,
                                    sessionID: sessionID,
                                    answers: draft.answerPayload(for: request)
                                )
                            } else {
                                focusedQuestionID = nil
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                                    stepIndex = clampedStep + 1
                                }
                            }
                        }
                    )

                    AgentQuestionStepActionBar(
                        request: request,
                        stepIndex: $stepIndex,
                        isSubmitting: isSubmitting,
                        isDisabled: !canAnswer,
                        allowsEmptySubmission: true,
                        skipAccessibilityIdentifier: "conversation.asyncQuestion.skip",
                        primaryAccessibilityIdentifier: clampedStep >= totalSteps - 1
                            ? "conversation.asyncQuestion.submit"
                            : "conversation.asyncQuestion.next",
                        draft: $draft,
                        onPrepareAction: { focusedQuestionID = nil },
                        onSubmit: { answers in
                            sessionStore.answerAsyncQuestion(message, sessionID: sessionID, answers: answers) != nil
                        }
                    )

                    if !canAnswer && !isSubmitting {
                        Text(L10n.text("ui.async_question_control_required"))
                            .font(themeStore.uiFont(.caption))
                            .foregroundStyle(tokens.secondaryText)
                    }
                }
            }
            .foregroundStyle(tokens.primaryText)
            .padding(16)
            .frame(maxWidth: layout.runtimeCardMaxWidth, alignment: .leading)
            .modifier(AgentRequestCardSurface(tokens: tokens, borderColor: tokens.border))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("conversation.asyncQuestion")
            .onChange(of: request.questions.count) { _, newCount in
                if stepIndex >= max(1, newCount) {
                    stepIndex = max(0, newCount - 1)
                }
            }
            .onChange(of: progress) { _, current in
                if current.isResolved(question) || current.isExpired {
                    focusedQuestionID = nil
                }
            }
        }
    }

    @ViewBuilder
    private func questionTitlesSummary(
        question: CodexAsyncQuestion,
        progress: CodexAsyncQuestionProgress,
        tokens: ThemeTokens
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(question.questions.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title)
                        .font(themeStore.uiFont(.subheadline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                    if progress.answeredIndices.contains(index) && !progress.isResolved(question) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(themeStore.uiFont(.caption))
                            .foregroundStyle(tokens.accent)
                    }
                }
            }
        }
    }
}

struct ConversationDesktopWorktreeNotice: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let message: ConversationMessage
    let layout: ConversationLayout

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(L10n.text("ui.desktop_worktree_title"), systemImage: "desktopcomputer")
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.secondaryText)
                Spacer(minLength: 0)
                if let status = message.activityPayload?.displayStatusText {
                    Text(status)
                        .font(themeStore.uiFont(.caption2, weight: .medium))
                        .foregroundStyle(tokens.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(tokens.elevatedSurface, in: Capsule())
                }
            }
            Text(L10n.text("ui.desktop_worktree_notice"))
                .font(themeStore.uiFont(.subheadline))
                .foregroundStyle(tokens.primaryText)
        }
        .padding(16)
        .frame(maxWidth: layout.runtimeCardMaxWidth, alignment: .leading)
        .modifier(AgentRequestCardSurface(tokens: tokens, borderColor: tokens.border))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("conversation.desktopWorktreeNotice")
    }
}
