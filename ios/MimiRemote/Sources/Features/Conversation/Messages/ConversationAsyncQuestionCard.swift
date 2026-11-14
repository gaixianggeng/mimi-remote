import SwiftUI

struct ConversationAsyncQuestionCard: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var conversationStore: ConversationStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let message: ConversationMessage
    let layout: ConversationLayout
    let sessionID: SessionID?
    @State private var showsForm = false
    @State private var draft = PendingUserInputDraft()

    var body: some View {
        if let question = message.activityPayload?.asyncQuestion, let sessionID,
           let session = sessionStore.sessionsByID[sessionID] {
            let progress = CodexAsyncQuestionProgress.make(
                question: question, message: message, messages: conversationStore.messages(for: sessionID)
            )
            let isSubmitting = progress.isSubmitting || sessionStore.isAnsweringAsyncQuestion(question, sessionID: sessionID)
            let canAnswer = sessionStore.canAnswerAsyncQuestion(message, sessionID: sessionID) && !isSubmitting
            let request = question.request(sessionID: sessionID, turnID: message.turnID, answeredIndices: progress.answeredIndices)
            let tokens = themeStore.tokens(for: colorScheme)
            VStack(alignment: .leading, spacing: 12) {
                Label(L10n.text("ui.async_question_title"), systemImage: "questionmark.bubble")
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.secondaryText)
                ForEach(Array(question.questions.enumerated()), id: \.offset) { index, item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title)
                            .font(themeStore.uiFont(.body, weight: .medium))
                        ForEach(Array(item.options.enumerated()), id: \.offset) { _, option in
                            Text("• \(option)")
                                .font(themeStore.uiFont(.subheadline))
                                .foregroundStyle(tokens.secondaryText)
                        }
                        if progress.answeredIndices.contains(index) {
                            Label(L10n.text("ui.async_question_answered"), systemImage: "checkmark.circle")
                                .font(themeStore.uiFont(.caption))
                                .foregroundStyle(tokens.secondaryText)
                        }
                    }
                }
                if progress.isExpired {
                    Text(L10n.text("ui.supplemental_information_request_expired"))
                        .foregroundStyle(tokens.secondaryText)
                } else if !progress.isResolved(question) {
                    Button(isSubmitting ? L10n.text("ui.submitting") : L10n.text("ui.async_question_answer")) {
                        showsForm = true
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                    .disabled(!canAnswer)
                    .accessibilityIdentifier("conversation.asyncQuestion.answer")
                    if !canAnswer && !isSubmitting {
                        Text(L10n.text("ui.async_question_control_required"))
                            .font(themeStore.uiFont(.caption))
                            .foregroundStyle(tokens.secondaryText)
                    }
                }
            }
            .foregroundStyle(tokens.primaryText)
            .padding(14)
            .frame(maxWidth: layout.runtimeCardMaxWidth, alignment: .leading)
            .background(tokens.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tokens.border, lineWidth: 1))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("conversation.asyncQuestion")
            .sheet(isPresented: $showsForm) {
                PendingUserInputSheet(
                    presentation: PendingUserInputPresentation(request: request, runtimePresentation: SessionRuntimePresentation(session: session)),
                    isSubmitting: isSubmitting || !canAnswer,
                    draft: $draft,
                    onSubmit: { answers in
                        sessionStore.answerAsyncQuestion(message, sessionID: sessionID, answers: answers) != nil
                    }
                )
            }
            .onChange(of: progress) { _, current in
                if current.isResolved(question) || current.isExpired { showsForm = false }
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
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.text("ui.desktop_worktree_title"), systemImage: "desktopcomputer")
                .font(themeStore.uiFont(.subheadline, weight: .semibold))
            if let status = message.activityPayload?.displayStatusText {
                Text(status).font(themeStore.uiFont(.caption)).foregroundStyle(tokens.secondaryText)
            }
            Text(L10n.text("ui.desktop_worktree_notice"))
                .font(themeStore.uiFont(.subheadline))
                .foregroundStyle(tokens.secondaryText)
        }
        .padding(14)
        .frame(maxWidth: layout.runtimeCardMaxWidth, alignment: .leading)
        .background(tokens.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tokens.border, lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("conversation.desktopWorktreeNotice")
    }
}
