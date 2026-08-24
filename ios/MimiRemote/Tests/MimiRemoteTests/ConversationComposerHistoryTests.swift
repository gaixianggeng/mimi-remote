import XCTest
import AVFoundation
import Combine
import Security
import SwiftUI
import UIKit
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testAppleSpeechHealthMonitorOnlyArmsAfterSustainedAudibleInput() {
        var monitor = AppleSpeechHealthMonitor()

        XCTAssertNil(monitor.observeLevel(0.05, at: 1))
        XCTAssertNil(monitor.observeLevel(0.8, at: 2))
        XCTAssertNil(monitor.observeLevel(0.8, at: 2.25))
        XCTAssertNil(monitor.observeLevel(0.8, at: 2.5))
        XCTAssertEqual(monitor.observeLevel(0.8, at: 2.7), 1)
        XCTAssertTrue(monitor.isAwaitingResult(generation: 1))
    }

    func testAppleSpeechHealthMonitorResetsAfterGapAndAfterResult() {
        var monitor = AppleSpeechHealthMonitor()

        XCTAssertNil(monitor.observeLevel(0.8, at: 1))
        XCTAssertNil(monitor.observeLevel(0.8, at: 1.2))
        XCTAssertNil(monitor.observeLevel(0.05, at: 1.6))
        XCTAssertNil(monitor.observeLevel(0.8, at: 2))
        XCTAssertNil(monitor.observeLevel(0.8, at: 2.25))
        XCTAssertNil(monitor.observeLevel(0.8, at: 2.5))
        XCTAssertEqual(monitor.observeLevel(0.8, at: 2.7), 1)

        monitor.observeResult()

        XCTAssertFalse(monitor.isAwaitingResult(generation: 1))
        XCTAssertNil(monitor.observeLevel(0.8, at: 3))
        XCTAssertNil(monitor.observeLevel(0.8, at: 3.25))
        XCTAssertNil(monitor.observeLevel(0.8, at: 3.5))
        XCTAssertEqual(monitor.observeLevel(0.8, at: 3.7), 2)
    }

    func testAppleSpeechHealthMonitorDisarmsAfterSilenceAndCanRearm() {
        var monitor = AppleSpeechHealthMonitor()

        XCTAssertNil(monitor.observeLevel(0.8, at: 1))
        XCTAssertNil(monitor.observeLevel(0.8, at: 1.25))
        XCTAssertNil(monitor.observeLevel(0.8, at: 1.5))
        XCTAssertEqual(monitor.observeLevel(0.8, at: 1.7), 1)
        XCTAssertTrue(monitor.isAwaitingResult(generation: 1))

        XCTAssertNil(monitor.observeLevel(0.05, at: 1.8))
        XCTAssertTrue(monitor.isAwaitingResult(generation: 1))
        XCTAssertNil(monitor.observeLevel(0.05, at: 2.1))
        XCTAssertFalse(monitor.isAwaitingResult(generation: 1))

        XCTAssertNil(monitor.observeLevel(0.8, at: 2.2))
        XCTAssertNil(monitor.observeLevel(0.8, at: 2.45))
        XCTAssertNil(monitor.observeLevel(0.8, at: 2.7))
        XCTAssertEqual(monitor.observeLevel(0.8, at: 2.9), 2)
        XCTAssertTrue(monitor.isAwaitingResult(generation: 2))
    }

    func testAppleSpeechAudioSessionEventParsesInterruptionNotifications() {
        let began = Notification(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
                AVAudioSessionInterruptionReasonKey: UInt(1)
            ]
        )
        let ended = Notification(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue
            ]
        )

        XCTAssertEqual(
            AppleSpeechAudioSessionEvent.interruption(from: began),
            .interruptionBegan(reasonRawValue: 1)
        )
        XCTAssertEqual(
            AppleSpeechAudioSessionEvent.interruption(from: ended),
            .interruptionEnded
        )
        XCTAssertNil(
            AppleSpeechAudioSessionEvent.interruption(
                from: Notification(name: AVAudioSession.routeChangeNotification)
            )
        )
    }

    func testImageAttachmentEncoderDownsamplesLargeScreenshotAndProducesJPEGDataURL() throws {
        let sourceSize = CGSize(width: 2_732, height: 2_048)
        let rendererFormat = UIGraphicsImageRendererFormat.default()
        rendererFormat.scale = 1
        let renderer = UIGraphicsImageRenderer(size: sourceSize, format: rendererFormat)
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(origin: .zero, size: sourceSize))
            UIColor.white.setFill()
            context.fill(CGRect(x: 80, y: 80, width: 1_200, height: 180))
        }
        let sourceData = try XCTUnwrap(image.pngData())

        let prepared = try ImageAttachmentEncoder.prepare(sourceData)

        XCTAssertTrue(prepared.dataURL.hasPrefix("data:image/jpeg;base64,"))
        XCTAssertLessThanOrEqual(max(prepared.pixelWidth, prepared.pixelHeight), ImageAttachmentEncoder.maximumPixelDimension)
        XCTAssertLessThanOrEqual(prepared.encodedByteCount, ImageAttachmentEncoder.targetEncodedByteCount)
        let payload = try XCTUnwrap(prepared.dataURL.split(separator: ",", maxSplits: 1).last)
        let encodedData = try XCTUnwrap(Data(base64Encoded: String(payload)))
        let decodedImage = try XCTUnwrap(UIImage(data: encodedData))
        XCTAssertEqual(Int(decodedImage.size.width), prepared.pixelWidth)
        XCTAssertEqual(Int(decodedImage.size.height), prepared.pixelHeight)
    }

    func testImageAttachmentEncoderDoesNotUpscaleSmallImage() throws {
        let sourceSize = CGSize(width: 640, height: 480)
        let rendererFormat = UIGraphicsImageRendererFormat.default()
        rendererFormat.scale = 1
        let image = UIGraphicsImageRenderer(size: sourceSize, format: rendererFormat).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(origin: .zero, size: sourceSize))
        }
        let prepared = try ImageAttachmentEncoder.prepare(try XCTUnwrap(image.pngData()))

        XCTAssertEqual(prepared.pixelWidth, 640)
        XCTAssertEqual(prepared.pixelHeight, 480)
    }

    func testComposerPlanAndGoalModesDoNotUseGuidedDelivery() {
        var composerState = ComposerState()

        XCTAssertEqual(
            composerState.runningTurnDelivery(canUseGuidedFollowUp: true, guidedFollowUpEnabled: true),
            .guided
        )

        composerState.togglePlanMode()
        XCTAssertEqual(
            composerState.runningTurnDelivery(canUseGuidedFollowUp: true, guidedFollowUpEnabled: true),
            .queued
        )

        composerState.resetTransientSendMode()
        composerState.toggleGoalMode()
        XCTAssertEqual(
            composerState.runningTurnDelivery(canUseGuidedFollowUp: true, guidedFollowUpEnabled: true),
            .queued
        )
    }

    func testComposerPrimaryActionKeepsRunningTurnSubmissionAndStopReachable() {
        XCTAssertEqual(
            ComposerPrimaryAction.resolve(
                canSubmitDraft: false,
                canStopCurrentReply: true
            ),
            .stopCurrentReply,
            "运行中且草稿为空或暂时不可提交时，停止当前回复必须保持可达"
        )
        XCTAssertEqual(
            ComposerPrimaryAction.resolve(
                canSubmitDraft: true,
                canStopCurrentReply: true
            ),
            .submit,
            "用户准备好可提交的下一条消息后，发送/排队必须重新成为主操作"
        )
        XCTAssertEqual(
            ComposerPrimaryAction.resolve(
                canSubmitDraft: false,
                canStopCurrentReply: false
            ),
            .submit,
            "非运行状态仍保留普通发送按钮，并由按钮自身表达禁用状态"
        )
    }

    func testComposerStateCanSubmitWithStandardModeSanitizedOptions() throws {
        var composerState = ComposerState()
        composerState.draft = "用标准模式提交"
        composerState.turnOptions.runtimeProvider = "claude"
        composerState.turnOptions.model = "gpt-5-codex"
        composerState.turnOptions.modelProvider = "openai"
        composerState.turnOptions.serviceTier = "priority"
        composerState.turnOptions.reasoningEffort = .high
        composerState.turnOptions.reasoningSummary = .detailed
        composerState.turnOptions.personality = .friendly
        composerState.turnOptions.approvalPolicy = .onRequest
        composerState.turnOptions.approvalsReviewer = "auto_review"
        composerState.turnOptions.sandboxMode = .readOnly
        composerState.turnOptions.networkAccess = true
        composerState.turnOptions.config = .object(["approval_policy": .string("never")])
        composerState.turnOptions.baseInstructions = "base"
        composerState.turnOptions.developerInstructions = "dev"
        composerState.turnOptions.outputSchema = .object(["type": .string("object")])
        composerState.turnOptions.serviceName = "ios"
        composerState.turnOptions.sessionStartSource = "ipad"
        composerState.turnOptions.threadSource = "user"

        let submitted = try XCTUnwrap(composerState.takeDraftForSubmit(
            isLoading: false,
            turnOptionsOverride: composerState.turnOptions.sanitizedForStandardComposer()
        ))
        let options = submitted.payload.options

        XCTAssertEqual(options.runtimeProvider, "claude")
        XCTAssertEqual(options.model, "gpt-5-codex")
        XCTAssertNil(options.modelProvider)
        XCTAssertEqual(options.serviceTier, "priority")
        XCTAssertEqual(options.reasoningEffort, .high)
        XCTAssertEqual(options.reasoningSummary, .detailed)
        XCTAssertEqual(options.personality, .friendly)
        XCTAssertEqual(options.approvalPolicy, .onRequest)
        XCTAssertEqual(options.approvalsReviewer, "user")
        XCTAssertEqual(options.sandboxMode, .readOnly)
        XCTAssertFalse(options.networkAccess)
        XCTAssertNil(options.config)
        XCTAssertNil(options.baseInstructions)
        XCTAssertNil(options.developerInstructions)
        XCTAssertNil(options.outputSchema)
        XCTAssertNil(options.serviceName)
        XCTAssertNil(options.sessionStartSource)
        XCTAssertNil(options.threadSource)
        XCTAssertEqual(options.collaborationMode, .default)
    }

    func testComposerStateStandardModePreservesAutoApprovalPreset() throws {
        var composerState = ComposerState()
        composerState.draft = "用替我审批提交"
        composerState.applyPermissionMode(.autoApprove)
        composerState.turnOptions.networkAccess = true
        composerState.turnOptions.config = .object(["feature": .bool(true)])

        let submitted = try XCTUnwrap(composerState.takeDraftForSubmit(
            isLoading: false,
            turnOptionsOverride: composerState.turnOptions.sanitizedForStandardComposer()
        ))
        let options = submitted.payload.options

        XCTAssertEqual(options.approvalPolicy, .onRequest)
        XCTAssertEqual(options.approvalsReviewer, "auto_review")
        XCTAssertEqual(options.sandboxMode, .workspaceWrite)
        XCTAssertFalse(options.networkAccess)
        XCTAssertNil(options.config)
        XCTAssertEqual(options.collaborationMode, .default)
    }

    func testComposerStandardModeClearsPreviousPlanModeToDefault() throws {
        var options = CodexAppServerTurnOptions.default
        options.collaborationMode = .plan

        let standard = options.sanitizedForStandardComposer()

        XCTAssertEqual(standard.collaborationMode, .default)
    }

    func testComposerGoalSubmissionPayloadUsesDefaultCollaborationMode() throws {
        var composerState = ComposerState()
        composerState.draft = "完成目标任务"
        composerState.toggleGoalMode()
        var goalOptions = composerState.turnOptions.sanitizedForStandardComposer()
        // 目标模式的目标状态走 thread/goal/set；turn/start 必须显式回到 default。
        goalOptions.collaborationMode = .default

        let submitted = try XCTUnwrap(composerState.takeDraftForSubmit(
            isLoading: false,
            turnOptionsOverride: goalOptions
        ))

        XCTAssertEqual(submitted.payload.options.collaborationMode, .default)
    }

    func testConversationSendRegressionMatrixKeepsModesAttachmentsVoiceAndPermissionsIndependent() throws {
        var composerState = ComposerState()
        let projectPath = "/tmp/conversation-regression"

        composerState.draft = "先规划完整链路"
        composerState.togglePlanMode()
        composerState.addAttachment(.image(url: "https://example.test/diagram.png", detail: .high))
        composerState.addAttachment(.image(url: "data:image/png;base64,AA==", detail: .low))
        composerState.addAttachment(.localImage(path: "\(projectPath)/screen.png", detail: .original))
        composerState.addAttachment(.skill(name: "review", path: "\(projectPath)/.codex/skills/review/SKILL.md"))
        composerState.addAttachment(.mention(name: "README", path: "\(projectPath)/README.md"))
        var planOptions = composerState.turnOptions
        planOptions.collaborationMode = .plan

        let planSubmission = try XCTUnwrap(composerState.takeDraftForSubmit(
            isLoading: false,
            turnOptionsOverride: planOptions
        ))
        XCTAssertEqual(planSubmission.payload.options.collaborationMode, .plan)
        XCTAssertEqual(planSubmission.payload.input.count, 6)
        XCTAssertEqual(planSubmission.payload.textPrompt, "先规划完整链路")
        XCTAssertTrue(payloadContainsImageURL(planSubmission.payload, url: "https://example.test/diagram.png"))
        XCTAssertTrue(payloadContainsInlineImage(planSubmission.payload))
        XCTAssertTrue(planSubmission.payload.input.contains {
            if case .localImage(let path, _) = $0 {
                return path == "\(projectPath)/screen.png"
            }
            return false
        })
        XCTAssertTrue(payloadContainsSkill(planSubmission.payload, name: "review"))
        XCTAssertTrue(payloadContainsMention(planSubmission.payload, name: "README"))

        // 回归：上一条 Plan 的本地 options 即使被沿用，普通发送也必须 sanitize 回 default。
        composerState.turnOptions = planSubmission.payload.options
        composerState.resetSendModeAfterSubmit()
        composerState.draft = "切回普通模式"
        let standardSubmission = try XCTUnwrap(composerState.takeDraftForSubmit(
            isLoading: false,
            turnOptionsOverride: composerState.turnOptions.sanitizedForStandardComposer()
        ))
        XCTAssertEqual(standardSubmission.payload.options.collaborationMode, .default)
        XCTAssertEqual(standardSubmission.payload.textPrompt, "切回普通模式")

        composerState.restore("切到目标模式")
        composerState.toggleGoalMode()
        var goalOptions = composerState.turnOptions.sanitizedForStandardComposer()
        goalOptions.collaborationMode = .default
        let goalSubmission = try XCTUnwrap(composerState.takeDraftForSubmit(
            isLoading: false,
            turnOptionsOverride: goalOptions
        ))
        XCTAssertEqual(goalSubmission.payload.options.collaborationMode, .default)
        XCTAssertEqual(
            composerState.runningTurnDelivery(canUseGuidedFollowUp: true, guidedFollowUpEnabled: true),
            .queued
        )

        composerState.resetSendModeAfterSubmit()
        composerState.beginVoiceInput()
        composerState.applyVoiceTranscript("语音目标任务")
        composerState.toggleGoalMode()
        let voiceGoalSubmission = try XCTUnwrap(composerState.takeDraftForSubmit(
            isLoading: false,
            turnOptionsOverride: composerState.turnOptions.sanitizedForStandardComposer()
        ))
        XCTAssertTrue(voiceGoalSubmission.voiceDraftNeedsReview)
        XCTAssertEqual(voiceGoalSubmission.payload.textPrompt, "语音目标任务")
        XCTAssertEqual(voiceGoalSubmission.payload.options.collaborationMode, .default)

        composerState.resetSendModeAfterSubmit()
        composerState.beginVoiceInput()
        composerState.applyVoiceTranscript("语音计划任务")
        composerState.togglePlanMode()
        var voicePlanOptions = composerState.turnOptions.sanitizedForStandardComposer()
        voicePlanOptions.collaborationMode = .plan
        let voicePlanSubmission = try XCTUnwrap(composerState.takeDraftForSubmit(
            isLoading: false,
            turnOptionsOverride: voicePlanOptions
        ))
        XCTAssertTrue(voicePlanSubmission.voiceDraftNeedsReview)
        XCTAssertEqual(voicePlanSubmission.payload.options.collaborationMode, .plan)
    }

    func testComposerPermissionRegressionMatrixKeepsNetworkDisabled() throws {
        let cases: [(mode: ComposerPermissionMode, policy: CodexAppServerApprovalPolicy, reviewer: String, sandbox: CodexAppServerSandboxMode)] = [
            (.readOnly, .onRequest, "user", .readOnly),
            (.requestApproval, .onRequest, "user", .workspaceWrite),
            (.autoApprove, .onRequest, "auto_review", .workspaceWrite),
            (.fullAccess, .never, "user", .dangerFullAccess)
        ]

        for testCase in cases {
            var composerState = ComposerState()
            composerState.draft = "权限矩阵 \(testCase.mode.rawValue)"
            composerState.applyPermissionMode(testCase.mode)
            composerState.turnOptions.networkAccess = true

            let submitted = try XCTUnwrap(composerState.takeDraftForSubmit(
                isLoading: false,
                turnOptionsOverride: composerState.turnOptions.sanitizedForStandardComposer()
            ))
            let options = submitted.payload.options
            XCTAssertEqual(options.approvalPolicy, testCase.policy, "mode=\(testCase.mode)")
            XCTAssertEqual(options.approvalsReviewer, testCase.reviewer, "mode=\(testCase.mode)")
            XCTAssertEqual(options.sandboxMode, testCase.sandbox, "mode=\(testCase.mode)")
            // 移动端所有权限预设都不打开 networkAccess，避免一次发送把网络权限带进 app-server。
            XCTAssertFalse(options.networkAccess, "mode=\(testCase.mode)")
            XCTAssertEqual(options.collaborationMode, .default, "mode=\(testCase.mode)")
        }
    }

    func testComposerStateStandardModePreservesFullAccessPreset() throws {
        var composerState = ComposerState()
        composerState.draft = "用完全访问提交"
        composerState.applyPermissionMode(.fullAccess)
        composerState.turnOptions.networkAccess = true
        composerState.turnOptions.config = .object(["feature": .bool(true)])

        let submitted = try XCTUnwrap(composerState.takeDraftForSubmit(
            isLoading: false,
            turnOptionsOverride: composerState.turnOptions.sanitizedForStandardComposer()
        ))
        let options = submitted.payload.options

        XCTAssertEqual(options.approvalPolicy, .never)
        XCTAssertEqual(options.approvalsReviewer, "user")
        XCTAssertEqual(options.sandboxMode, .dangerFullAccess)
        XCTAssertFalse(options.networkAccess)
        XCTAssertNil(options.config)
    }

    func testComposerStateVoiceTranscriptPreservesManualEditsDuringRecording() {
        var composerState = ComposerState()
        composerState.draft = "已有上下文"
        composerState.beginVoiceInput()
        composerState.applyVoiceTranscript("第一段")
        XCTAssertEqual(composerState.draft, "已有上下文\n第一段")
        XCTAssertTrue(composerState.voiceDraftNeedsReview)

        composerState.draft += "\n手动补充"
        composerState.applyVoiceTranscript("第二段")

        XCTAssertEqual(composerState.draft, "已有上下文\n第一段\n手动补充\n第二段")
        XCTAssertTrue(composerState.voiceDraftNeedsReview)
        composerState.endVoiceInput()
    }

    func testRealtimeVoiceTranscriptReplacesVolatileTextAndKeepsManualSuffix() {
        var composerState = ComposerState()
        composerState.draft = "已有上下文"
        composerState.beginVoiceInput()

        composerState.applyRealtimeVoiceTranscript("检查项目")
        XCTAssertEqual(composerState.draft, "已有上下文\n检查项目")

        composerState.draft += "\n手动补充"
        composerState.applyRealtimeVoiceTranscript("检查项目并补测试")

        XCTAssertEqual(composerState.draft, "已有上下文\n检查项目并补测试\n手动补充")
        XCTAssertTrue(composerState.voiceDraftNeedsReview)
        composerState.endVoiceInput()
    }

    func testAppleSpeechTranscriptAccumulatorReplacesVolatileAndAppendsFinalSegments() {
        var accumulator = AppleSpeechTranscriptAccumulator()

        accumulator.apply("检查", isFinal: false)
        XCTAssertEqual(accumulator.text, "检查")
        accumulator.apply("检查项目", isFinal: false)
        XCTAssertEqual(accumulator.text, "检查项目")
        accumulator.apply("检查项目", isFinal: true)
        accumulator.apply("并补测试", isFinal: false)
        XCTAssertEqual(accumulator.text, "检查项目并补测试")
        accumulator.apply("并补测试", isFinal: true)
        XCTAssertEqual(accumulator.text, "检查项目并补测试")
        accumulator.apply("误识别", isFinal: false)
        accumulator.apply("", isFinal: true)
        XCTAssertEqual(accumulator.text, "检查项目并补测试")
    }

    func testVoiceInputToggleStateMachineCancelsPreparingAndIgnoresTranscribing() {
        let scenarios: [
            (
                isPressActive: Bool,
                isPreparing: Bool,
                isRecording: Bool,
                isTranscribing: Bool,
                expected: VoiceInputToggleAction
            )
        ] = [
            (false, false, false, false, .start),
            (true, false, false, false, .end),
            (false, true, false, false, .end),
            (false, false, true, false, .end),
            (true, true, false, false, .end),
            (true, true, true, true, .ignore)
        ]

        for scenario in scenarios {
            XCTAssertEqual(
                VoiceInputToggleAction.resolve(
                    isPressActive: scenario.isPressActive,
                    isPreparing: scenario.isPreparing,
                    isRecording: scenario.isRecording,
                    isTranscribing: scenario.isTranscribing
                ),
                scenario.expected,
                "state=\(scenario)"
            )
        }
    }

    func testPreparingVoiceMicButtonStateRemainsEnabledAndDescribesCancel() {
        let state = VoiceMicButtonState(
            isPreparing: true,
            isRecording: false,
            isTranscribing: false
        )
        let host = hostVoiceMicButton(
            isPreparing: true,
            isRecording: false,
            isTranscribing: false
        )
        let fittedSize = host.sizeThatFits(in: CGSize(width: 200, height: 200))

        XCTAssertTrue(state.isEnabled)
        XCTAssertEqual(state.accessibilityTitle, L10n.text("ui.end_voice_input"))
        XCTAssertEqual(state.accessibilityValue, L10n.text("ui.preparing"))
        XCTAssertEqual(
            state.accessibilityHint(usesRealtimeTranscription: false),
            L10n.text("ui.tap_to_cancel_voice_input_preparation")
        )
        XCTAssertGreaterThanOrEqual(fittedSize.width, 44)
        XCTAssertGreaterThanOrEqual(fittedSize.height, 44)
    }

    func testTranscribingVoiceMicButtonStateStaysDisabledAndHasNoActionHint() {
        let state = VoiceMicButtonState(
            isPreparing: false,
            isRecording: false,
            isTranscribing: true
        )
        let host = hostVoiceMicButton(
            isPreparing: false,
            isRecording: false,
            isTranscribing: true
        )
        let fittedSize = host.sizeThatFits(in: CGSize(width: 200, height: 200))

        XCTAssertFalse(state.isEnabled)
        XCTAssertEqual(state.accessibilityTitle, L10n.text("ui.transcribing_speech"))
        XCTAssertEqual(state.accessibilityValue, L10n.text("ui.transcribing"))
        XCTAssertTrue(state.accessibilityHint(usesRealtimeTranscription: false).isEmpty)
        XCTAssertGreaterThanOrEqual(fittedSize.width, 44)
        XCTAssertGreaterThanOrEqual(fittedSize.height, 44)
    }

    func testVoiceAudioSessionCoordinatorSerializesLifecycleAndIgnoresStaleCleanup() async throws {
        let backend = RecordingVoiceAudioSessionBackend()
        let coordinator = VoiceAudioSessionCoordinator(backend: backend)

        try await coordinator.prewarm()
        let firstActivation = try await coordinator.activate()
        let secondActivation = try await coordinator.activate()
        await coordinator.deactivate(firstActivation)

        // 第一轮清理晚到时不能关闭第二轮刚激活的会话。
        XCTAssertEqual(
            backend.operations,
            [.prepare, .prepare, .activate, .prepare, .activate]
        )

        await coordinator.deactivate(secondActivation)
        let deadline = ContinuousClock.now + .milliseconds(250)
        while backend.operations.last != .deactivate, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(
            backend.operations,
            [.prepare, .prepare, .activate, .prepare, .activate, .deactivate]
        )
        XCTAssertFalse(backend.wasCalledOnMainThread)
    }

    func testVoiceAudioSessionCoordinatorPropagatesActivationFailure() async {
        let backend = RecordingVoiceAudioSessionBackend(failingOperation: .activate)
        let coordinator = VoiceAudioSessionCoordinator(backend: backend)

        do {
            _ = try await coordinator.activate()
            XCTFail("Expected activation failure")
        } catch let error as RecordingVoiceAudioSessionBackend.TestError {
            XCTAssertEqual(error, .requestedFailure(.activate))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(backend.operations, [.prepare, .activate])
        XCTAssertFalse(backend.wasCalledOnMainThread)
    }

    func testComposerStateVoiceDraftRequiresReviewUntilSubmitted() throws {
        var composerState = ComposerState()
        XCTAssertFalse(composerState.voiceDraftNeedsReview)

        composerState.beginVoiceInput()
        composerState.applyVoiceTranscript("重启后端服务")

        XCTAssertEqual(composerState.draft, "重启后端服务")
        XCTAssertTrue(composerState.voiceDraftNeedsReview)

        let submitted = try XCTUnwrap(composerState.takeDraftForSubmit(isLoading: false))

        XCTAssertTrue(submitted.voiceDraftNeedsReview)
        XCTAssertFalse(composerState.voiceDraftNeedsReview)

        composerState.restore(submitted)
        XCTAssertTrue(composerState.voiceDraftNeedsReview)

        composerState.draft = ""
        XCTAssertFalse(composerState.voiceDraftNeedsReview)
    }

    func testComposerStateVoiceReviewFlagDoesNotLeakIntoTypedRestore() throws {
        var composerState = ComposerState()
        composerState.beginVoiceInput()
        composerState.applyVoiceTranscript("检查发布文案")
        XCTAssertTrue(composerState.voiceDraftNeedsReview)

        composerState.restore("手动输入的新任务")

        XCTAssertEqual(composerState.draft, "手动输入的新任务")
        XCTAssertFalse(composerState.voiceDraftNeedsReview)

        let submitted = try XCTUnwrap(composerState.takeDraftForSubmit(isLoading: false))
        XCTAssertFalse(submitted.voiceDraftNeedsReview)
    }

    func testVoiceTranscriptionDefaultsFollowCurrentLocaleWithEnglishFallback() {
        let expected = Locale.autoupdatingCurrent.language.languageCode?.identifier ?? "en"
        XCTAssertEqual(VoiceTranscriptionDefaults.languageCode, expected)
    }

    func testVoiceTranscriptionRequestOnlyEncodesCodexFields() throws {
        let request = VoiceTranscriptionRequest(
            filename: "voice.m4a",
            contentType: "audio/mp4",
            audioBase64: "dGVzdA==",
            language: VoiceTranscriptionDefaults.languageCode
        )
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(object.keys), ["filename", "content_type", "audio_base64", "language"])
    }

    func testTextSelectionPolicyMovesExternalAppendCaretToEnd() {
        let first = TextSelectionPolicy.rangeAfterExternalTextSync(
            previousText: "",
            nextText: "第一段",
            previousRange: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(first.location, ("第一段" as NSString).length)
        XCTAssertEqual(first.length, 0)

        let previous = "第一段"
        let next = "第一段\n第二段"
        let second = TextSelectionPolicy.rangeAfterExternalTextSync(
            previousText: previous,
            nextText: next,
            previousRange: NSRange(location: (previous as NSString).length, length: 0)
        )
        XCTAssertEqual(second.location, (next as NSString).length)
        XCTAssertEqual(second.length, 0)
    }

    func testTextSelectionPolicyPreservesMiddleCaretForEndpointEditing() {
        let endpoint = "http://192.168.1.20:8787"
        let range = TextSelectionPolicy.rangeAfterExternalTextSync(
            previousText: endpoint,
            nextText: endpoint,
            previousRange: NSRange(location: 12, length: 0)
        )

        XCTAssertEqual(range.location, 12)
        XCTAssertEqual(range.length, 0)
    }

    func testComposerTextSubmitBridgeKeepsOrdinaryCompositionSnapshotNonDestructive() throws {
        let textView = CommandSubmitTextView()
        textView.text = "继续"
        textView.selectedRange = NSRange(location: (textView.text as NSString).length, length: 0)
        textView.setMarkedText("修复", selectedRange: NSRange(location: 2, length: 0))
        let bridge = ComposerTextSubmitBridge()
        bridge.attach(textView)

        let snapshot = try XCTUnwrap(bridge.snapshotForSubmit())

        XCTAssertEqual(snapshot.text, "继续修复")
        XCTAssertTrue(snapshot.isComposing)
        XCTAssertTrue(textView.hasMarkedText, "普通草稿快照不能提前提交输入法组合态")
    }

    func testComposerTextSubmitBridgeFinalSnapshotCommitsChineseMarkedText() throws {
        let textView = CommandSubmitTextView()
        textView.text = "继续"
        textView.selectedRange = NSRange(location: (textView.text as NSString).length, length: 0)
        textView.setMarkedText("修复", selectedRange: NSRange(location: 2, length: 0))
        let bridge = ComposerTextSubmitBridge()
        bridge.attach(textView)

        let snapshot = try XCTUnwrap(bridge.finalSnapshotForSubmit())

        XCTAssertEqual(snapshot.text, "继续修复")
        XCTAssertFalse(snapshot.isComposing)
        XCTAssertFalse(textView.hasMarkedText)
    }

    func testComposerTextSubmitBridgeTreatsActiveChineseCompositionAsSubmittableText() {
        let textView = CommandSubmitTextView()
        textView.setMarkedText("继续修复", selectedRange: NSRange(location: 4, length: 0))
        let bridge = ComposerTextSubmitBridge()
        bridge.attach(textView)

        XCTAssertTrue(textView.hasMarkedText)
        XCTAssertTrue(bridge.hasNonWhitespaceTextForSubmit())
    }

    func testSkillAutocompleteThenChineseSubmitBuildsTextAndSkillPayload() throws {
        let skillToken = "$review"
        let textView = CommandSubmitTextView()
        textView.text = skillToken
        textView.selectedRange = NSRange(location: (skillToken as NSString).length, length: 0)
        let bridge = ComposerTextSubmitBridge()
        bridge.attach(textView)
        let query = try XCTUnwrap(ComposerSkillQuery.match(
            text: skillToken,
            selectedRange: textView.selectedRange
        ))

        XCTAssertEqual(bridge.replaceText(in: query.replacementRange, with: ""), "")
        textView.setMarkedText("帮我继续修复", selectedRange: NSRange(location: 6, length: 0))
        let finalSnapshot = try XCTUnwrap(bridge.finalSnapshotForSubmit())

        var composerState = ComposerState()
        composerState.draft = finalSnapshot.text
        composerState.addAttachment(.skill(name: "review", path: "/tmp/review/SKILL.md"))
        let submitted = try XCTUnwrap(composerState.takeDraftForSubmit(isLoading: false))

        XCTAssertEqual(submitted.payload.textPrompt, "帮我继续修复")
        XCTAssertTrue(payloadContainsSkill(submitted.payload, name: "review"))
        XCTAssertEqual(submitted.payload.input.count, 2)
    }

    func testComposerFocusRequestIsConsumedOnceAndDoesNotClearNewerRequest() {
        let first = UUID()
        let second = UUID()

        XCTAssertEqual(
            ComposerFocusRequestPolicy.requestToConsume(pending: first, lastHandled: nil),
            first
        )
        XCTAssertNil(
            ComposerFocusRequestPolicy.requestToConsume(pending: first, lastHandled: first),
            "同一个 UIView 生命周期内不能重复消费焦点请求"
        )
        XCTAssertNil(
            ComposerFocusRequestPolicy.pendingRequest(afterConsuming: first, current: first),
            "消费完成后必须清空父 View 的 token，避免新 UITextView 再次弹键盘"
        )
        XCTAssertEqual(
            ComposerFocusRequestPolicy.pendingRequest(afterConsuming: first, current: second),
            second,
            "旧异步回调不能误清理刚产生的新焦点请求"
        )
        XCTAssertNil(ComposerFocusRequestPolicy.requestToConsume(pending: nil, lastHandled: nil))
    }

    func testVoiceWaveformLevelMappingBoostsQuietSpeechWithoutAnimatingSilence() {
        XCTAssertEqual(VoiceWaveformLevelMapping.visualLevel(for: 0), 0, accuracy: 0.001)
        XCTAssertEqual(VoiceWaveformLevelMapping.visualLevel(for: 0.02), 0, accuracy: 0.001)

        let quiet = VoiceWaveformLevelMapping.visualLevel(for: 0.10)
        let normal = VoiceWaveformLevelMapping.visualLevel(for: 0.35)
        let loud = VoiceWaveformLevelMapping.visualLevel(for: 0.75)

        XCTAssertGreaterThan(quiet, 0.30)
        XCTAssertGreaterThan(normal, quiet)
        XCTAssertGreaterThan(normal - quiet, 0.20)
        XCTAssertGreaterThan(loud, 0.85)
        XCTAssertLessThanOrEqual(VoiceWaveformLevelMapping.visualLevel(for: 2), 1)
    }

    func testVoiceWaveformSampleShapeUsesCurrentLevelWithoutScrollingHistory() {
        let silence = VoiceWaveformSampleShape.samples(for: 0.01, count: 9)
        XCTAssertEqual(silence, Array(repeating: 0, count: 9))

        let first = VoiceWaveformSampleShape.samples(for: 0.45, count: 9)
        let second = VoiceWaveformSampleShape.samples(for: 0.45, count: 9)

        XCTAssertEqual(first, second)
        XCTAssertGreaterThan(first[4], first[0])
        XCTAssertGreaterThan(first[4], first[8])
        XCTAssertEqual(first[0], first[8], accuracy: 0.001)
        XCTAssertEqual(first[1], first[7], accuracy: 0.001)
    }

    func testRuntimeActivityDisplayTiersExposeLastEventEvidence() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let snapshot = RuntimeActivitySnapshot(
            turnStartedAt: startedAt,
            lastActivityAt: startedAt.addingTimeInterval(70)
        )

        let fresh = RuntimeActivityDisplay.make(
            snapshot: snapshot,
            webSocketStatus: .connected,
            now: startedAt.addingTimeInterval(80)
        )
        XCTAssertEqual(fresh?.tone, .active)
        XCTAssertEqual(fresh?.detailText, "运行 01:20 · 最后活动 10 秒前")

        let waiting = RuntimeActivityDisplay.make(
            snapshot: snapshot,
            webSocketStatus: .connected,
            now: startedAt.addingTimeInterval(140)
        )
        XCTAssertEqual(waiting?.tone, .neutral)
        XCTAssertTrue(waiting?.detailText.contains("等待输出") == true)

        let stale = RuntimeActivityDisplay.make(
            snapshot: snapshot,
            webSocketStatus: .connected,
            now: startedAt.addingTimeInterval(180)
        )
        XCTAssertEqual(stale?.tone, .warning)
        XCTAssertTrue(stale?.detailText.contains("连接正常") == true)

        let disconnected = RuntimeActivityDisplay.make(
            snapshot: snapshot,
            webSocketStatus: .disconnected,
            now: startedAt.addingTimeInterval(80)
        )
        XCTAssertEqual(disconnected?.tone, .warning)
        XCTAssertTrue(disconnected?.detailText.contains("连接断开") == true)
    }

    func testHistoryMergeDeduplicatesLocalEchoByRoleAndContent() {
        let store = ConversationStore()
        let sessionID = "sess_data_flow"
        let now = Date()

        // 本地回显先进入对话列表，后端历史确认到达后必须合并到同一条消息语义上。
        store.appendUser("帮我检查测试结构", sessionID: sessionID)
        store.setHistory([
            CodexHistoryMessage(role: "user", content: "帮我检查测试结构", createdAt: now.addingTimeInterval(-2)),
            CodexHistoryMessage(role: "assistant", content: "已检查。", createdAt: now.addingTimeInterval(-1))
        ], sessionID: sessionID)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(messages.filter { $0.role == .user && $0.content == "帮我检查测试结构" }.count, 1)
        XCTAssertTrue(store.hasLoadedHistory(sessionID: sessionID))
    }

    func testStructuredHistoryConfirmsLocalEchoByClientMessageID() {
        let store = ConversationStore()
        let sessionID = "sess_structured_history"
        let clientMessageID = "client-history-1"

        store.appendLocalUser("帮我检查历史会话", sessionID: sessionID, clientMessageID: clientMessageID, sendStatus: .sending)
        store.setHistory([
            CodexHistoryMessage(
                id: "msg_history_1",
                role: "user",
                content: "帮我检查历史会话",
                createdAt: Date(timeIntervalSince1970: 1),
                clientMessageID: clientMessageID,
                revision: 1,
                sendStatus: .confirmed
            )
        ], sessionID: sessionID)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.stableID, "msg_history_1")
        XCTAssertEqual(messages.first?.clientMessageID, clientMessageID)
        XCTAssertEqual(messages.first?.sendStatus, .confirmed)
        XCTAssertEqual(messages.first?.revision, 1)
    }

    func testDirectAppServerHistoryDeduplicatesLiveCompletedAssistantItem() {
        let store = ConversationStore()
        let sessionID = "thread_direct_dedup"
        let turnID = "turn_direct_dedup"
        let itemID = "assistant_direct_dedup"
        let stableID = "appserver:\(turnID):\(itemID)"
        let answer = "有。\n\n程序员结婚后第一次吵架。"
        let metadata = AgentEventMetadata(
            seq: 1,
            sessionID: sessionID,
            turnID: turnID,
            itemID: itemID,
            messageID: stableID,
            clientMessageID: nil,
            revision: 1,
            createdAt: nil
        )

        store.completeMessage(
            AgentMessage(
                id: stableID,
                sessionID: sessionID,
                turnID: turnID,
                itemID: itemID,
                role: .assistant,
                content: answer,
                createdAt: Date(timeIntervalSince1970: 20),
                seq: 1,
                revision: 1,
                sendStatus: .confirmed
            ),
            metadata: metadata,
            fallbackSessionID: sessionID
        )

        store.setHistory([
            CodexHistoryMessage(
                id: itemID,
                role: "assistant",
                content: answer,
                createdAt: Date(timeIntervalSince1970: 10),
                turnID: turnID,
                itemID: itemID,
                revision: 1,
                sendStatus: .confirmed
            )
        ], sessionID: sessionID)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.stableID, stableID)
        XCTAssertEqual(messages.first?.turnID, turnID)
        XCTAssertEqual(messages.first?.itemID, itemID)
        XCTAssertEqual(messages.first?.content, answer)
    }

    func testHistoryDeduplicatesLiveAssistantWhenThreadReadRenumbersItemID() {
        // 复刻真实抓包：流式 item/completed 用 app-server 真实 id(msg_…)，而 thread/read 把同一条助手
        // 消息重排成整条线程的全局顺序号(item-N)；turnId 与最终文本两边一致。手动刷新时必须合并为一条。
        let store = ConversationStore()
        let sessionID = "thread_renumber"
        let turnID = "019ea77f-608a-7be0-9ae1-3bf9d3421370"
        let liveItemID = "msg_0457a91708aef848016a26c89602288195938ee282e5218165"
        let historyItemID = "item-8"
        let answer = "面试官：“你最大的缺点是什么？”\n\n程序员：“太诚实。”"

        store.completeMessage(
            AgentMessage(
                id: "appserver:\(turnID):\(liveItemID)",
                sessionID: sessionID,
                turnID: turnID,
                itemID: liveItemID,
                role: .assistant,
                content: answer,
                createdAt: Date(timeIntervalSince1970: 20),
                seq: 1,
                revision: 1,
                sendStatus: .confirmed
            ),
            metadata: AgentEventMetadata(
                seq: 1,
                sessionID: sessionID,
                turnID: turnID,
                itemID: liveItemID,
                messageID: "appserver:\(turnID):\(liveItemID)",
                clientMessageID: nil,
                revision: 1,
                createdAt: nil
            ),
            fallbackSessionID: sessionID
        )

        store.setHistory([
            CodexHistoryMessage(
                id: "appserver:\(turnID):\(historyItemID)",
                role: "assistant",
                content: answer,
                createdAt: Date(timeIntervalSince1970: 10),
                turnID: turnID,
                itemID: historyItemID,
                revision: 1,
                sendStatus: .confirmed,
                isTimestampFallback: true
            )
        ], sessionID: sessionID)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 1, "itemId 不一致(msg_… vs item-N)但 turnId+文本一致时应合并为一条，而不是刷新后重复")
        XCTAssertEqual(messages.first?.role, .assistant)
        XCTAssertEqual(messages.first?.content, answer)
    }

    func testHistoryDeduplicatesLiveProcessMessagesWhenThreadReadRenumbersItemID() throws {
        // 过程卡和最终 assistant 一样会遇到 thread/read 重排 item id；同一 turn、同一类过程卡、
        // 同一文本应保留历史快照，丢弃 websocket replay 的直播副本。
        let store = ConversationStore()
        let sessionID = "thread_process_renumber"
        let turnID = "turn_process_renumber"
        let liveItemID = "msg_live_reasoning"
        let historyItemID = "item-5"
        let summary = "我先确认历史数据与实时 replay 的边界。"

        store.completeMessage(
            AgentMessage(
                id: "appserver:\(turnID):\(liveItemID)",
                sessionID: sessionID,
                turnID: turnID,
                itemID: liveItemID,
                role: .system,
                kind: .reasoningSummary,
                content: summary,
                createdAt: Date(timeIntervalSince1970: 20),
                seq: 1,
                revision: 1,
                sendStatus: .confirmed
            ),
            metadata: AgentEventMetadata(
                seq: 1,
                sessionID: sessionID,
                turnID: turnID,
                itemID: liveItemID,
                messageID: "appserver:\(turnID):\(liveItemID)",
                clientMessageID: nil,
                revision: 1,
                createdAt: nil
            ),
            fallbackSessionID: sessionID
        )

        store.setHistory([
            CodexHistoryMessage(
                id: "appserver:\(turnID):\(historyItemID)",
                role: "system",
                kind: .reasoningSummary,
                content: summary,
                createdAt: Date(timeIntervalSince1970: 10),
                turnID: turnID,
                itemID: historyItemID,
                revision: 1,
                sendStatus: .confirmed,
                isTimestampFallback: true
            )
        ], sessionID: sessionID)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.role, .system)
        XCTAssertEqual(messages.first?.kind, .reasoningSummary)
        XCTAssertEqual(messages.first?.content, summary)
        XCTAssertEqual(messages.first?.createdAt, Date(timeIntervalSince1970: 20), "去重后应保留 history 身份，但回填 live 真实时间，避免历史刷新把过程项拖回 turn.startedAt")
        XCTAssertFalse(try XCTUnwrap(messages.first).isTimestampFallback)
    }

    func testHistoryMergePlacesLiveOnlyCommandBetweenEstimatedHistoryNeighbors() {
        let store = ConversationStore()
        let sessionID = "thread_live_command_order"
        let turnID = "turn_live_command_order"

        store.appendSystem(
            "命令：grep -n activeTurnID",
            sessionID: sessionID,
            kind: .commandSummary,
            metadata: AgentEventMetadata(
                seq: 2,
                sessionID: sessionID,
                turnID: turnID,
                itemID: "cmd_live_only",
                messageID: "cmd_live_only",
                clientMessageID: nil,
                revision: 1,
                createdAt: Date(timeIntervalSince1970: 20)
            )
        )
        store.setHistory([
            CodexHistoryMessage(
                id: "user_history_order",
                role: "user",
                content: "先排查",
                createdAt: Date(timeIntervalSince1970: 10),
                turnID: turnID,
                itemID: "user_history_order",
                timelineOrdinal: 0,
                isTimestampFallback: true
            ),
            CodexHistoryMessage(
                id: "plan_history_order",
                role: "system",
                kind: .plan,
                content: "修复历史排序",
                createdAt: Date(timeIntervalSince1970: 30),
                turnID: turnID,
                itemID: "plan_history_order",
                timelineOrdinal: 2,
                isTimestampFallback: true
            )
        ], sessionID: sessionID)

        XCTAssertEqual(
            store.messages(for: sessionID).map(\.content),
            ["先排查", "命令：grep -n activeTurnID", "修复历史排序"]
        )
    }

    func testAuthoritativeCompletedHistoryPrunesMissingProjectedProcessItems() {
        let store = ConversationStore()
        let sessionID = "thread_projected_orphan_prune"
        let turnID = "turn_projected_orphan_prune"

        store.setHistory([
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-1",
                role: "user",
                content: "检查排序",
                createdAt: Date(timeIntervalSince1970: 10),
                turnID: turnID,
                itemID: "item-1",
                timelineOrdinal: 1
            ),
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-20",
                role: "system",
                kind: .plan,
                content: "给出修复计划",
                createdAt: Date(timeIntervalSince1970: 20),
                turnID: turnID,
                itemID: "item-20",
                timelineOrdinal: 20
            ),
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-21",
                role: "system",
                kind: .commandSummary,
                content: "命令：git diff",
                createdAt: Date(timeIntervalSince1970: 10.021),
                turnID: turnID,
                itemID: "item-21",
                timelineOrdinal: 21,
                isTimestampFallback: true
            ),
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-22",
                role: "system",
                kind: .commandSummary,
                content: "命令：grep -n ConversationStore",
                createdAt: Date(timeIntervalSince1970: 10.022),
                turnID: turnID,
                itemID: "item-22",
                timelineOrdinal: 22,
                isTimestampFallback: true
            )
        ], sessionID: sessionID)
        XCTAssertEqual(store.messages(for: sessionID).filter { $0.kind == .commandSummary }.count, 2)

        store.setHistory([
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-1",
                role: "user",
                content: "检查排序",
                createdAt: Date(timeIntervalSince1970: 10),
                turnID: turnID,
                itemID: "item-1",
                timelineOrdinal: 1
            ),
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-20",
                role: "system",
                kind: .plan,
                content: "给出修复计划",
                createdAt: Date(timeIntervalSince1970: 20),
                turnID: turnID,
                itemID: "item-20",
                timelineOrdinal: 20
            )
        ], sessionID: sessionID, authoritativeCompletedTurnItems: [
            turnID: ["item-1", "item-20"]
        ])

        XCTAssertEqual(store.messages(for: sessionID).map(\.content), ["检查排序", "给出修复计划"])
        XCTAssertFalse(store.messages(for: sessionID).contains { $0.itemID == "item-21" || $0.itemID == "item-22" })
    }

    func testAuthoritativeCompletedHistoryKeepsLiveProcessItemsWithoutTimelineOrdinal() {
        let store = ConversationStore()
        let sessionID = "thread_live_process_preserve"
        let turnID = "turn_live_process_preserve"

        store.appendSystem(
            "命令：git diff",
            sessionID: sessionID,
            kind: .commandSummary,
            metadata: AgentEventMetadata(
                seq: 2,
                sessionID: sessionID,
                turnID: turnID,
                itemID: "cmd_live_1",
                messageID: "appserver:\(turnID):cmd_live_1",
                clientMessageID: nil,
                revision: 1,
                createdAt: Date(timeIntervalSince1970: 15)
            )
        )

        store.setHistory([
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-1",
                role: "user",
                content: "检查排序",
                createdAt: Date(timeIntervalSince1970: 10),
                turnID: turnID,
                itemID: "item-1",
                timelineOrdinal: 1
            ),
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-20",
                role: "system",
                kind: .plan,
                content: "给出修复计划",
                createdAt: Date(timeIntervalSince1970: 20),
                turnID: turnID,
                itemID: "item-20",
                timelineOrdinal: 20
            )
        ], sessionID: sessionID, authoritativeCompletedTurnItems: [
            turnID: ["item-1", "item-20"]
        ])

        let messages = store.messages(for: sessionID)
        XCTAssertTrue(messages.contains { $0.itemID == "cmd_live_1" && $0.timelineOrdinal == nil })
        XCTAssertEqual(messages.map(\.content), ["检查排序", "命令：git diff", "给出修复计划"])
    }

    func testSummaryHistoryDoesNotPruneMissingProjectedProcessItems() {
        let store = ConversationStore()
        let sessionID = "thread_summary_no_prune"
        let turnID = "turn_summary_no_prune"

        store.setHistory([
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-1",
                role: "user",
                content: "检查排序",
                createdAt: Date(timeIntervalSince1970: 10),
                turnID: turnID,
                itemID: "item-1",
                timelineOrdinal: 1
            ),
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-21",
                role: "system",
                kind: .commandSummary,
                content: "命令：git diff",
                createdAt: Date(timeIntervalSince1970: 10.021),
                turnID: turnID,
                itemID: "item-21",
                timelineOrdinal: 21,
                isTimestampFallback: true
            )
        ], sessionID: sessionID)

        store.setHistory([
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-1",
                role: "user",
                content: "检查排序",
                createdAt: Date(timeIntervalSince1970: 10),
                turnID: turnID,
                itemID: "item-1",
                timelineOrdinal: 1
            )
        ], sessionID: sessionID)

        XCTAssertTrue(store.messages(for: sessionID).contains { $0.itemID == "item-21" })
    }

    func testAuthoritativeCompletedHistoryKeepsProjectedProcessItemsPresentInTurnItemSet() {
        let store = ConversationStore()
        let sessionID = "thread_window_process_preserve"
        let turnID = "turn_window_process_preserve"

        store.setHistory([
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-1",
                role: "user",
                content: "检查排序",
                createdAt: Date(timeIntervalSince1970: 10),
                turnID: turnID,
                itemID: "item-1",
                timelineOrdinal: 1
            ),
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-30",
                role: "system",
                kind: .commandSummary,
                content: "工具：browser.open\n状态：completed",
                createdAt: Date(timeIntervalSince1970: 30),
                turnID: turnID,
                itemID: "item-30",
                timelineOrdinal: 30
            ),
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-31",
                role: "system",
                kind: .fileChangeSummary,
                content: "文件变更：Sources/App.swift",
                createdAt: Date(timeIntervalSince1970: 31),
                turnID: turnID,
                itemID: "item-31",
                timelineOrdinal: 31
            )
        ], sessionID: sessionID)

        // 核心逻辑：thread/read 兜底按消息切窗口，当前页可能没带这个工具卡；
        // 只要 runtime 的完整 turn item 集合证明它仍存在，就不能当 orphan 清理。
        store.setHistory([
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-1",
                role: "user",
                content: "检查排序",
                createdAt: Date(timeIntervalSince1970: 10),
                turnID: turnID,
                itemID: "item-1",
                timelineOrdinal: 1
            )
        ], sessionID: sessionID, authoritativeCompletedTurnItems: [
            turnID: ["item-1", "item-30", "item-31"]
        ])

        XCTAssertTrue(store.messages(for: sessionID).contains { $0.itemID == "item-30" })
        XCTAssertTrue(store.messages(for: sessionID).contains { $0.itemID == "item-31" })
    }

    func testHistoryMergeKeepsSnapshotSourceOrderWhenTimestampsConflict() throws {
        let store = ConversationStore()
        let sessionID = "thread_fallback_plan_before_accurate_command"
        let turnID = "turn_fallback_plan_before_accurate_command"

        store.setHistory([
            CodexHistoryMessage(
                id: "plan_fallback",
                role: "system",
                kind: .plan,
                content: "先列出修复计划。",
                createdAt: Date(timeIntervalSince1970: 38),
                turnID: turnID,
                itemID: "plan_fallback",
                timelineOrdinal: 2,
                isTimestampFallback: true
            ),
            CodexHistoryMessage(
                id: "cmd_accurate",
                role: "system",
                kind: .commandSummary,
                content: "命令：grep -n ConversationStore",
                createdAt: Date(timeIntervalSince1970: 32),
                turnID: turnID,
                itemID: "cmd_accurate",
                timelineOrdinal: 3
            )
        ], sessionID: sessionID)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.map(\.content), ["先列出修复计划。", "命令：grep -n ConversationStore"])
        XCTAssertTrue(try XCTUnwrap(messages.first).isTimestampFallback)
        XCTAssertFalse(try XCTUnwrap(messages.last).isTimestampFallback)
    }

    func testReplayedLiveCompletionWithOlderTimestampSortsBeforeEstimatedPlan() {
        // 回放事故回归：merge 先落地（含橙色估算 plan），断线回放的命令卡随后带着更早的
        // 原始时间戳到达；它必须插回 plan 之前，而不是钉在时间线尾部。
        let store = ConversationStore()
        let sessionID = "thread_replay_after_merge"
        let turnID = "turn_replay_after_merge"

        store.setHistory([
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-0",
                role: "user",
                content: "先排查",
                createdAt: Date(timeIntervalSince1970: 10),
                turnID: turnID,
                itemID: "item-0",
                timelineOrdinal: 0
            ),
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-11",
                role: "system",
                kind: .plan,
                content: "# 修复计划",
                createdAt: Date(timeIntervalSince1970: 38),
                turnID: turnID,
                itemID: "item-11",
                timelineOrdinal: 11,
                isTimestampFallback: true
            )
        ], sessionID: sessionID)

        store.completeMessage(
            AgentMessage(
                id: "appserver:\(turnID):cmd_live",
                sessionID: sessionID,
                turnID: turnID,
                itemID: "cmd_live",
                role: .system,
                kind: .commandSummary,
                content: "命令：grep -n ConversationStore",
                createdAt: Date(timeIntervalSince1970: 32),
                seq: 9,
                revision: 9,
                sendStatus: .confirmed
            ),
            metadata: AgentEventMetadata(
                seq: 9,
                sessionID: sessionID,
                turnID: turnID,
                itemID: "cmd_live",
                messageID: "appserver:\(turnID):cmd_live",
                clientMessageID: nil,
                revision: 9,
                createdAt: nil
            ),
            fallbackSessionID: sessionID
        )

        XCTAssertEqual(
            store.messages(for: sessionID).map(\.content),
            ["先排查", "命令：grep -n ConversationStore", "# 修复计划"],
            "回放追加的旧时间戳命令卡应插回估算 plan 之前"
        )
    }

    func testReplayedPlanCompletionBackfillsEstimatedHistoryTwinInsteadOfDuplicating() throws {
        // thread/read 把 plan item id 重排后，回放的 plan completed 带的是流式 id；
        // 同 turn 同文本时应回填历史孪生卡的真实时间，而不是再补一张重复卡。
        let store = ConversationStore()
        let sessionID = "thread_replay_plan_twin"
        let turnID = "turn_replay_plan_twin"
        let planText = "# 设置与连接入口收敛方案"

        store.setHistory([
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-11",
                role: "system",
                kind: .plan,
                content: planText,
                createdAt: Date(timeIntervalSince1970: 38),
                turnID: turnID,
                itemID: "item-11",
                timelineOrdinal: 11,
                isTimestampFallback: true
            )
        ], sessionID: sessionID)

        store.completeMessage(
            AgentMessage(
                id: "appserver:\(turnID):plan_live",
                sessionID: sessionID,
                turnID: turnID,
                itemID: "plan_live",
                role: .system,
                kind: .plan,
                content: planText,
                createdAt: Date(timeIntervalSince1970: 41),
                seq: 12,
                revision: 12,
                sendStatus: .confirmed
            ),
            metadata: AgentEventMetadata(
                seq: 12,
                sessionID: sessionID,
                turnID: turnID,
                itemID: "plan_live",
                messageID: "appserver:\(turnID):plan_live",
                clientMessageID: nil,
                revision: 12,
                createdAt: nil
            ),
            fallbackSessionID: sessionID
        )

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 1, "回放的 plan completed 应合并进历史孪生卡，而不是再补一张")
        let plan = try XCTUnwrap(messages.first)
        XCTAssertEqual(plan.kind, .plan)
        XCTAssertFalse(plan.isTimestampFallback, "live 真实时间应回填，估算标记要清除")
        XCTAssertEqual(plan.createdAt, Date(timeIntervalSince1970: 41))
        XCTAssertEqual(plan.sendStatus, .confirmed)
    }

    func testReplayedPlanTwinBackfillUpdatesInPlaceWithoutReordering() {
        let store = ConversationStore()
        let sessionID = "thread_replay_plan_twin_resort"
        let turnID = "turn_replay_plan_twin_resort"
        let planText = "# 修复计划"

        store.setHistory([
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-2",
                role: "system",
                kind: .plan,
                content: planText,
                createdAt: Date(timeIntervalSince1970: 38),
                turnID: turnID,
                itemID: "item-2",
                timelineOrdinal: 2,
                isTimestampFallback: true
            ),
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-3",
                role: "system",
                kind: .commandSummary,
                content: "命令：go test ./...",
                createdAt: Date(timeIntervalSince1970: 32),
                turnID: turnID,
                itemID: "item-3",
                timelineOrdinal: 3
            )
        ], sessionID: sessionID)

        XCTAssertEqual(
            store.messages(for: sessionID).map(\.content),
            [planText, "命令：go test ./..."]
        )

        store.completeMessage(
            AgentMessage(
                id: "appserver:\(turnID):plan_live",
                sessionID: sessionID,
                turnID: turnID,
                itemID: "plan_live",
                role: .system,
                kind: .plan,
                content: planText,
                createdAt: Date(timeIntervalSince1970: 31),
                seq: 12,
                revision: 12,
                sendStatus: .confirmed
            ),
            metadata: AgentEventMetadata(
                seq: 12,
                sessionID: sessionID,
                turnID: turnID,
                itemID: "plan_live",
                messageID: "appserver:\(turnID):plan_live",
                clientMessageID: nil,
                revision: 12,
                createdAt: nil
            ),
            fallbackSessionID: sessionID
        )

        XCTAssertEqual(
            store.messages(for: sessionID).map(\.content),
            [planText, "命令：go test ./..."],
            "live 真实时间只能更新首次出现槽位，不能触发已有 Item 重排"
        )
    }

    func testHistoryMergeKeepsStableOrderWhenOrdinalAndLiveTimesConflict() {
        let store = ConversationStore()
        let sessionID = "thread_conflicting_timeline_order"
        let turnID = "turn_conflicting_timeline_order"

        store.appendSystem(
            "命令：sed -n '1,40p' EventReducer.swift",
            sessionID: sessionID,
            kind: .commandSummary,
            metadata: AgentEventMetadata(
                seq: 2,
                sessionID: sessionID,
                turnID: turnID,
                itemID: "cmd_live_conflict",
                messageID: "cmd_live_conflict",
                clientMessageID: nil,
                revision: 1,
                createdAt: Date(timeIntervalSince1970: 120)
            )
        )
        store.setHistory([
            CodexHistoryMessage(
                id: "plan_conflict",
                role: "system",
                kind: .plan,
                content: "先给出计划。",
                createdAt: Date(timeIntervalSince1970: 131),
                turnID: turnID,
                itemID: "plan_conflict",
                timelineOrdinal: 5
            ),
            CodexHistoryMessage(
                id: "user_conflict",
                role: "user",
                content: "要求后续变更",
                createdAt: Date(timeIntervalSince1970: 104),
                turnID: turnID,
                itemID: "user_conflict",
                timelineOrdinal: 6,
                userDelivery: .injected
            )
        ], sessionID: sessionID)

        XCTAssertEqual(
            store.messages(for: sessionID).map(\.content),
            ["命令：sed -n '1,40p' EventReducer.swift", "先给出计划。", "要求后续变更"]
        )
    }

    func testHistoryKeepsDistinctProcessMessagesInSameTurn() {
        let store = ConversationStore()
        let sessionID = "thread_process_distinct"
        let turnID = "turn_process_distinct"

        store.setHistory([
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-1",
                role: "system",
                kind: .reasoningSummary,
                content: "先读取本地实现。",
                createdAt: Date(timeIntervalSince1970: 10),
                turnID: turnID,
                itemID: "item-1"
            ),
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-2",
                role: "system",
                kind: .reasoningSummary,
                content: "再和 Codex CLI 对齐。",
                createdAt: Date(timeIntervalSince1970: 11),
                turnID: turnID,
                itemID: "item-2"
            )
        ], sessionID: sessionID)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.map(\.content), ["先读取本地实现。", "再和 Codex CLI 对齐。"])
    }

    func testStructuredHistoryKeepsPlanAtSourcePositionBeforeFinalAssistant() throws {
        let store = ConversationStore()
        let sessionID = "sess_history_processed"
        let turnID = "turn_history_processed"

        store.setHistory([
            CodexHistoryMessage(
                id: "user_history_processed",
                role: "user",
                content: "调用子 agent 讲个笑话",
                createdAt: Date(timeIntervalSince1970: 10),
                turnID: turnID,
                itemID: "user_history_processed"
            ),
            CodexHistoryMessage(
                id: "commentary_history_processed",
                role: "assistant",
                kind: .commentary,
                content: "我先调用一个子 agent。",
                createdAt: Date(timeIntervalSince1970: 10),
                turnID: turnID,
                itemID: "commentary_history_processed"
            ),
            CodexHistoryMessage(
                id: "plan_history_processed",
                role: "system",
                kind: .plan,
                content: "让子 agent 生成一个短笑话。",
                createdAt: Date(timeIntervalSince1970: 12),
                turnID: turnID,
                itemID: "plan_history_processed"
            ),
            CodexHistoryMessage(
                id: "assistant_history_processed",
                role: "assistant",
                content: "程序员相亲，对方问：你会浪漫吗？",
                createdAt: Date(timeIntervalSince1970: 44),
                turnID: turnID,
                itemID: "assistant_history_processed"
            )
        ], sessionID: sessionID)

        let items = ConversationTimelineItemBuilder.items(from: store.messages(for: sessionID))

        XCTAssertEqual(items.count, 4)
        guard case .message(let commentary) = items[1] else {
            return XCTFail("history commentary 应作为完整正文放在最终 assistant 前")
        }
        XCTAssertEqual(commentary.kind, .commentary)
        XCTAssertEqual(commentary.content, "我先调用一个子 agent。")
        guard case .message(let plan) = items[2] else {
            return XCTFail("计划卡应保留在服务端输入顺序中的原始位置")
        }
        XCTAssertEqual(plan.kind, .plan)
        XCTAssertEqual(plan.content, "让子 agent 生成一个短笑话。")
        guard case .message(let final) = items[3] else {
            return XCTFail("最终 assistant 应保持独立展开")
        }
        XCTAssertEqual(final.role, .assistant)
        XCTAssertEqual(final.content, "程序员相亲，对方问：你会浪漫吗？")
    }

    func testHistoryDeduplicatesClientMessageEcho() {
        let store = ConversationStore()
        let sessionID = "sess_client_echo_history"
        let now = Date()

        store.appendLocalUser("讲个笑话", sessionID: sessionID, clientMessageID: "client-joke", sendStatus: .sent)
        store.setHistory([
            CodexHistoryMessage(role: "user", content: "讲个笑话", createdAt: now)
        ], sessionID: sessionID)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.role, .user)
        XCTAssertEqual(messages.first?.content, "讲个笑话")
    }

    func testConversationMessagesTrackCreatedAndCompletedTimes() throws {
        let store = ConversationStore()
        let sessionID = "sess_message_times"
        let startedAt = Date(timeIntervalSince1970: 100)
        let completedAt = Date(timeIntervalSince1970: 140)
        let startMetadata = AgentEventMetadata(
            seq: 1,
            sessionID: sessionID,
            turnID: "turn-times",
            itemID: "assistant-times",
            messageID: nil,
            clientMessageID: nil,
            revision: 1,
            createdAt: startedAt
        )

        store.applyAssistantDelta(
            AgentDelta(text: "正在处理", role: .assistant, kind: .message),
            metadata: startMetadata,
            fallbackSessionID: sessionID
        )

        var assistant = try XCTUnwrap(store.messages(for: sessionID).first)
        XCTAssertEqual(assistant.createdAt, startedAt)
        XCTAssertNil(assistant.updatedAt)

        let completionMetadata = AgentEventMetadata(
            seq: 2,
            sessionID: sessionID,
            turnID: "turn-times",
            itemID: "assistant-times",
            messageID: nil,
            clientMessageID: nil,
            revision: 2,
            createdAt: completedAt
        )
        store.markCurrentAssistantCompleted(metadata: completionMetadata, fallbackSessionID: sessionID)

        assistant = try XCTUnwrap(store.messages(for: sessionID).first)
        XCTAssertEqual(assistant.createdAt, startedAt)
        XCTAssertEqual(assistant.updatedAt, completedAt)

        store.setHistory([
            CodexHistoryMessage(
                id: "history-assistant-times",
                role: "assistant",
                content: "历史回复",
                createdAt: startedAt,
                updatedAt: completedAt,
                turnID: "history-turn",
                itemID: "history-assistant-times"
            )
        ], sessionID: "sess_history_message_times")

        let historyAssistant = try XCTUnwrap(store.messages(for: "sess_history_message_times").first)
        XCTAssertEqual(historyAssistant.createdAt, startedAt)
        XCTAssertEqual(historyAssistant.updatedAt, completedAt)
    }

    func testRepeatedUnstableHistoryProjectionKeepsMessageIdentity() {
        let store = ConversationStore()
        let sessionID = "sess_unstable_history_projection"
        let createdAt = Date(timeIntervalSince1970: 100)

        store.setHistory([
            CodexHistoryMessage(role: "user", content: "旧历史问题", createdAt: createdAt),
            CodexHistoryMessage(role: "assistant", content: "旧历史回答", createdAt: createdAt.addingTimeInterval(1))
        ], sessionID: sessionID)
        let firstIDs = store.messages(for: sessionID).map(\.id)

        // 上游历史项没有稳定 id 时，解码会补随机 UUID；语义相同的历史页重复绑定时，
        // 投影缓存应复用上一批 ConversationMessage，避免 SwiftUI 把整页当成新消息重绘。
        store.setHistory([
            CodexHistoryMessage(role: "user", content: "旧历史问题", createdAt: createdAt),
            CodexHistoryMessage(role: "assistant", content: "旧历史回答", createdAt: createdAt.addingTimeInterval(1))
        ], sessionID: sessionID)
        let replayed = store.messages(for: sessionID)

        XCTAssertEqual(replayed.map(\.id), firstIDs)
        XCTAssertEqual(replayed.map(\.content), ["旧历史问题", "旧历史回答"])
    }

    func testRepeatedIdenticalHistorySkipsMergeWork() {
        let store = ConversationStore()
        let sessionID = "sess_identical_history_fast_path"
        let createdAt = Date(timeIntervalSince1970: 150)
        let history = [
            CodexHistoryMessage(role: "user", content: "刷新问题", createdAt: createdAt),
            CodexHistoryMessage(role: "assistant", content: "刷新回答", createdAt: createdAt.addingTimeInterval(1))
        ]

        store.setHistory(history, sessionID: sessionID)
        XCTAssertEqual(store.historyMergeInvocationCountForTesting, 1)

        // 同一页历史重复刷新时，projection 已经能证明没有变化，不需要再次 merge/sort。
        store.setHistory(history, sessionID: sessionID)

        XCTAssertEqual(store.historyMergeInvocationCountForTesting, 1)
        XCTAssertTrue(store.hasLoadedHistory(sessionID: sessionID))
        XCTAssertEqual(store.messages(for: sessionID).map(\.content), ["刷新问题", "刷新回答"])
    }

    func testRepeatedLongHistoryProjectionSkipsMergeWork() {
        let store = ConversationStore()
        let sessionID = "sess_long_history_fast_path"
        let createdAt = Date(timeIntervalSince1970: 175)
        let longAnswer = String(repeating: "长回答内容", count: 8_000)
        let history = [
            CodexHistoryMessage(role: "user", content: "生成长回答", createdAt: createdAt),
            CodexHistoryMessage(role: "assistant", content: longAnswer, createdAt: createdAt.addingTimeInterval(1))
        ]

        store.setHistory(history, sessionID: sessionID)
        XCTAssertEqual(store.historyMergeInvocationCountForTesting, 1)

        // 长消息重复刷新时，Store 使用 content digest 判断等价，避免完整 content 参与热路径比较。
        store.setHistory(history, sessionID: sessionID)

        XCTAssertEqual(store.historyMergeInvocationCountForTesting, 1)
        XCTAssertEqual(store.messages(for: sessionID).last?.contentByteCount, longAnswer.utf8.count)
        XCTAssertEqual(store.messages(for: sessionID).last?.content, longAnswer)
    }

    func testGrowingUnstableHistoryProjectionReusesExistingRows() {
        let store = ConversationStore()
        let sessionID = "sess_growing_unstable_history"
        let createdAt = Date(timeIntervalSince1970: 200)
        let firstPage = [
            CodexHistoryMessage(role: "user", content: "第一轮问题", createdAt: createdAt),
            CodexHistoryMessage(role: "assistant", content: "第一轮回答", createdAt: createdAt.addingTimeInterval(1))
        ]

        store.setHistory(firstPage, sessionID: sessionID)
        let firstIDs = store.messages(for: sessionID).map(\.id)

        store.setHistory(firstPage + [
            CodexHistoryMessage(role: "assistant", content: "第二轮回答", createdAt: createdAt.addingTimeInterval(2))
        ], sessionID: sessionID)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(Array(messages.prefix(2)).map(\.id), firstIDs)
        XCTAssertEqual(messages.map(\.content), ["第一轮问题", "第一轮回答", "第二轮回答"])
    }

    func testPrependingUndatedHistoryReusesExistingSuffixRows() {
        let store = ConversationStore()
        let sessionID = "sess_prepend_undated_history"
        let beforeLoad = Date()

        store.setHistory([
            CodexHistoryMessage(role: "assistant", content: "现有回答", createdAt: nil)
        ], sessionID: sessionID)
        guard let existing = store.messages(for: sessionID).first else {
            return XCTFail("首屏历史应生成一条消息")
        }
        XCTAssertTrue(existing.isTimestampFallback)
        XCTAssertLessThan(existing.createdAt, beforeLoad.addingTimeInterval(-60), "历史缺时间时不能兜底成当前加载时间")
        XCTAssertFalse(existing.timestampCaptionText.hasPrefix("估 "))

        store.setHistory([
            CodexHistoryMessage(role: "user", content: "更早问题", createdAt: nil),
            CodexHistoryMessage(role: "assistant", content: "现有回答", createdAt: nil)
        ], sessionID: sessionID)

        let messages = store.messages(for: sessionID)
        let reused = messages.first { $0.content == "现有回答" }
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(reused?.id, existing.id)
        XCTAssertEqual(reused?.createdAt, existing.createdAt)
        XCTAssertEqual(reused?.isTimestampFallback, true)
        XCTAssertTrue(messages.allSatisfy(\.isTimestampFallback))
        XCTAssertTrue(messages.contains { $0.content == "更早问题" })
    }

    func testConversationStoreTrimsLeastRecentlyUsedSessionCaches() {
        let store = ConversationStore()
        let retainedLimit = ConversationStore.retainedSessionLimit
        let createdAt = Date(timeIntervalSince1970: 300)

        for index in 0..<retainedLimit {
            store.setHistory([
                CodexHistoryMessage(role: "assistant", content: "历史 \(index)", createdAt: createdAt.addingTimeInterval(TimeInterval(index)))
            ], sessionID: "sess_\(index)")
        }
        store.setHistory([
            CodexHistoryMessage(role: "assistant", content: "历史 0", createdAt: createdAt)
        ], sessionID: "sess_0")

        store.setHistory([
            CodexHistoryMessage(role: "assistant", content: "新历史", createdAt: createdAt.addingTimeInterval(TimeInterval(retainedLimit)))
        ], sessionID: "sess_new")

        XCTAssertEqual(store.messagesBySessionID.count, retainedLimit)
        XCTAssertEqual(store.messages(for: "sess_0").first?.content, "历史 0")
        XCTAssertTrue(store.messages(for: "sess_1").isEmpty)
        XCTAssertFalse(store.hasLoadedHistory(sessionID: "sess_1"))
        XCTAssertEqual(store.messages(for: "sess_new").first?.content, "新历史")
    }

    func testConversationStoreLRUTouchKeepsStreamingSessionHotAcrossEvictions() {
        let store = ConversationStore()
        let retainedLimit = ConversationStore.retainedSessionLimit
        let createdAt = Date(timeIntervalSince1970: 350)

        for index in 0..<retainedLimit {
            store.setHistory([
                CodexHistoryMessage(role: "assistant", content: "历史 \(index)", createdAt: createdAt.addingTimeInterval(TimeInterval(index)))
            ], sessionID: "sess_\(index)")
        }

        for index in 0..<5 {
            store.appendSystem("流式片段 \(index)", sessionID: "sess_0")
        }
        store.setHistory([
            CodexHistoryMessage(role: "assistant", content: "新历史 1", createdAt: createdAt.addingTimeInterval(TimeInterval(retainedLimit)))
        ], sessionID: "sess_new_1")
        store.setHistory([
            CodexHistoryMessage(role: "assistant", content: "新历史 2", createdAt: createdAt.addingTimeInterval(TimeInterval(retainedLimit + 1)))
        ], sessionID: "sess_new_2")

        XCTAssertEqual(store.messagesBySessionID.count, retainedLimit)
        XCTAssertTrue(store.messages(for: "sess_0").contains { $0.content == "流式片段 4" })
        XCTAssertTrue(store.messages(for: "sess_1").isEmpty)
        XCTAssertTrue(store.messages(for: "sess_2").isEmpty)
        XCTAssertEqual(store.messages(for: "sess_new_1").first?.content, "新历史 1")
        XCTAssertEqual(store.messages(for: "sess_new_2").first?.content, "新历史 2")
    }

    func testConversationStoreScopesSameSessionAndDelayedDeltaByProfile() async throws {
        let store = ConversationStore()
        let sessionID = "shared_session"

        store.activate(profileID: "mac-a")
        store.applyAssistantDelta(
            AgentDelta(text: "A", role: .assistant, kind: .message),
            metadata: AgentEventMetadata(
                seq: 1,
                sessionID: sessionID,
                turnID: "turn-a",
                itemID: "item-a",
                messageID: nil,
                clientMessageID: nil,
                revision: 1,
                createdAt: nil
            ),
            fallbackSessionID: sessionID
        )
        store.applyAssistantDelta(
            AgentDelta(text: " delayed", role: .assistant, kind: .message),
            metadata: AgentEventMetadata(
                seq: 2,
                sessionID: sessionID,
                turnID: "turn-a",
                itemID: "item-a",
                messageID: nil,
                clientMessageID: nil,
                revision: 2,
                createdAt: nil
            ),
            fallbackSessionID: sessionID
        )
        let macAMessageID = try XCTUnwrap(store.messages(for: sessionID).first?.id)

        store.activate(profileID: "mac-b")
        XCTAssertTrue(store.messages(for: sessionID).isEmpty)
        store.applyAssistantDelta(
            AgentDelta(text: "B only", role: .assistant, kind: .message),
            metadata: AgentEventMetadata(
                seq: 1,
                sessionID: sessionID,
                turnID: "turn-a",
                itemID: "item-a",
                messageID: nil,
                clientMessageID: nil,
                revision: 1,
                createdAt: nil
            ),
            fallbackSessionID: sessionID
        )

        // A 的 80ms delta flush 在切换后完成，也只能回写捕获的 A scoped key。
        // 必须让 mac-b 一直保持激活直到 flush 真正执行：若 flush 改回用 activeProfileID
        // 重算缓存键，就会在 mac-b 命名空间里查不到 A 的 pending 而静默丢弃。
        try await waitForPendingAssistantDeltaFlush(in: store)
        XCTAssertEqual(store.messages(for: sessionID).map(\.content), ["B only"])
        XCTAssertNotEqual(store.messages(for: sessionID).first?.id, macAMessageID)

        store.activate(profileID: "mac-a")
        XCTAssertEqual(store.messages(for: sessionID).map(\.content), ["A delayed"])
        XCTAssertEqual(store.lastSeenSeq(for: sessionID), 2)

        store.activate(profileID: "mac-b")
        XCTAssertEqual(store.lastSeenSeq(for: sessionID), 1)
    }

    func testConversationStoreUsesOneGlobalLRUBudgetAcrossProfiles() {
        let store = ConversationStore()
        let retainedLimit = ConversationStore.retainedSessionLimit
        let createdAt = Date(timeIntervalSince1970: 500)

        store.activate(profileID: "mac-a")
        for index in 0..<retainedLimit {
            store.setHistory(
                [CodexHistoryMessage(role: "assistant", content: "A \(index)", createdAt: createdAt)],
                sessionID: "sess_\(index)"
            )
        }

        store.activate(profileID: "mac-b")
        store.setHistory(
            [CodexHistoryMessage(role: "assistant", content: "B", createdAt: createdAt)],
            sessionID: "sess_b"
        )
        XCTAssertEqual(store.messages(for: "sess_b").first?.content, "B")

        store.activate(profileID: "mac-a")
        XCTAssertTrue(store.messages(for: "sess_0").isEmpty, "B 新增会话必须参与同一全局 32-session LRU")
        XCTAssertEqual(store.messages(for: "sess_1").first?.content, "A 1")
    }

    func testSelectingLoadedSessionRetainsConversationCache() async {
        let appStore = makeIsolatedAppStore()
        let conversationStore = ConversationStore()
        conversationStore.activate(profileID: appStore.activeHostScope.profileID)
        let retainedLimit = ConversationStore.retainedSessionLimit
        let createdAt = Date(timeIntervalSince1970: 400)
        let project = makeProject(id: "proj_lru")
        let selectedHistory = makeSession(id: "sess_0", projectID: project.id, title: "已加载历史", status: "history", source: "codex", resumeID: "sess_0")

        for index in 0..<retainedLimit {
            conversationStore.setHistory([
                CodexHistoryMessage(role: "assistant", content: "历史 \(index)", createdAt: createdAt.addingTimeInterval(TimeInterval(index)))
            ], sessionID: "sess_\(index)")
        }
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [project], sessions: [selectedHistory]) }
        )

        await store.selectSession(selectedHistory)
        conversationStore.setHistory([
            CodexHistoryMessage(role: "assistant", content: "新历史", createdAt: createdAt.addingTimeInterval(TimeInterval(retainedLimit)))
        ], sessionID: "sess_new")

        XCTAssertEqual(conversationStore.messagesBySessionID.count, retainedLimit)
        XCTAssertEqual(conversationStore.messages(for: selectedHistory.id).first?.content, "历史 0")
        XCTAssertTrue(conversationStore.messages(for: "sess_1").isEmpty)
        XCTAssertEqual(conversationStore.messages(for: "sess_new").first?.content, "新历史")
    }

    func testHistoryMergePreservesRepeatedUnstableMessagesWithSameText() {
        let store = ConversationStore()
        let sessionID = "sess_repeated_unstable_text"

        store.setHistory([
            CodexHistoryMessage(role: "user", content: "继续", createdAt: Date(timeIntervalSince1970: 10)),
            CodexHistoryMessage(role: "user", content: "继续", createdAt: Date(timeIntervalSince1970: 20))
        ], sessionID: sessionID)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.map(\.content), ["继续", "继续"])
        XCTAssertNotEqual(messages[0].id, messages[1].id)
    }

    func testHistoryEchoMergeRequiresNearbyHistoryTimestamp() {
        let store = ConversationStore()
        let sessionID = "sess_history_echo_window"

        store.appendUser("继续", sessionID: sessionID)
        store.setHistory([
            CodexHistoryMessage(role: "user", content: "继续", createdAt: Date(timeIntervalSince1970: 10))
        ], sessionID: sessionID)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.filter { $0.role == .user && $0.content == "继续" }.count, 2)
    }

    func testAgentEventDecodesStructuredAssistantDelta() throws {
        let decoder = JSONDecoder()

        let assistantDelta = try decoder.decode(
            AgentEvent.self,
            from: Data(#"{"type":"assistant_delta","delta":{"text":"结构化增量","role":"assistant","kind":"message"}}"#.utf8)
        )
        if case .assistantDelta(let delta, _) = assistantDelta {
            XCTAssertEqual(delta.text, "结构化增量")
        } else {
            XCTFail("Expected assistant delta event")
        }

        let resolved = try decoder.decode(
            AgentEvent.self,
            from: Data(#"{"type":"approval_resolved","seq":7,"session_id":"sess_output","item_id":"99"}"#.utf8)
        )
        if case .approvalResolved(let meta) = resolved {
            XCTAssertEqual(meta.seq, 7)
            XCTAssertEqual(meta.sessionID, "sess_output")
            XCTAssertEqual(meta.itemID, "99")
        } else {
            XCTFail("Expected approval resolved event")
        }
    }

    func testStructuredAssistantDeltaKeepsStableMetadata() throws {
        let decoder = JSONDecoder()

        let event = try decoder.decode(
            StructuredAgentEvent.self,
            from: Data(#"{"type":"assistant_delta","seq":42,"session_id":"sess_1","turn_id":"turn_1","item_id":"item_1","message_id":"msg_1","revision":3,"delta":{"text":"hello","role":"assistant","kind":"message"}}"#.utf8)
        )

        if case .assistantDelta(let delta, let meta) = event {
            XCTAssertEqual(delta.text, "hello")
            XCTAssertEqual(meta.seq, 42)
            XCTAssertEqual(meta.sessionID, "sess_1")
            XCTAssertEqual(meta.turnID, "turn_1")
            XCTAssertEqual(meta.itemID, "item_1")
            XCTAssertEqual(meta.messageID, "msg_1")
            XCTAssertEqual(meta.revision, 3)
        } else {
            XCTFail("Expected structured assistant delta")
        }
    }

    func testMessageCompletedOverwritesStreamingAssistantDeltaWithSameStableID() throws {
        let store = ConversationStore()
        let sessionID = "sess_completed_overwrites_delta"
        let stableID = "appserver:turn-1:assistant-1"
        let deltaMetadata = AgentEventMetadata(
            seq: 1,
            sessionID: sessionID,
            turnID: "turn-1",
            itemID: "assistant-1",
            messageID: stableID,
            clientMessageID: nil,
            revision: 1,
            createdAt: nil
        )
        store.applyAssistantDelta(
            AgentDelta(text: "Redis 去参加聚会。", role: .assistant, kind: .message),
            metadata: deltaMetadata,
            fallbackSessionID: sessionID
        )

        let completed = try JSONDecoder().decode(
            AgentMessage.self,
            from: Data("""
            {
              "id": "\(stableID)",
              "session_id": "\(sessionID)",
              "turn_id": "turn-1",
              "item_id": "assistant-1",
              "role": "assistant",
              "kind": "message",
              "content": "Redis 去参加聚会。\\n别人问它：你记性好吗？\\nRedis 说：特别好，但得看 TTL。",
              "revision": 2,
              "send_status": "confirmed"
            }
            """.utf8)
        )
        let completedMetadata = AgentEventMetadata(
            seq: 2,
            sessionID: sessionID,
            turnID: "turn-1",
            itemID: "assistant-1",
            messageID: stableID,
            clientMessageID: nil,
            revision: 2,
            createdAt: nil
        )

        store.completeMessage(completed, metadata: completedMetadata, fallbackSessionID: sessionID)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.stableID, stableID)
        XCTAssertEqual(messages.first?.content, completed.content)
        XCTAssertEqual(messages.first?.sendStatus, .confirmed)
        XCTAssertEqual(store.lastSeenSeq(for: sessionID), 2)
    }

    func testPaginateHistoryWindowsBackwardThroughEarliestMessage() {
        let messages = (0..<5).map { index in
            CodexHistoryMessage(id: "m\(index)", role: "user", content: "msg\(index)", createdAt: nil)
        }

        let latest = CodexAppServerSessionRuntime.paginateHistory(messages, before: nil, limit: 2)
        XCTAssertEqual(latest.messages.map(\.id), ["m3", "m4"])
        XCTAssertEqual(latest.previousCursor, "m3")
        XCTAssertTrue(latest.hasMoreBefore)

        let middle = CodexAppServerSessionRuntime.paginateHistory(messages, before: "m3", limit: 2)
        XCTAssertEqual(middle.messages.map(\.id), ["m1", "m2"])
        XCTAssertEqual(middle.previousCursor, "m1")
        XCTAssertTrue(middle.hasMoreBefore)

        // 翻到最早一窗时必须能拿到第一条 m0，并关闭分页入口。
        let earliest = CodexAppServerSessionRuntime.paginateHistory(messages, before: "m1", limit: 2)
        XCTAssertEqual(earliest.messages.map(\.id), ["m0"])
        XCTAssertNil(earliest.previousCursor)
        XCTAssertFalse(earliest.hasMoreBefore)
    }

    func testPaginateHistoryCarriesAuthoritativeTurnItemsAcrossWindowCuts() {
        let turnID = "turn_window_authority"
        let allItemIDs: [AgentItemID] = (20..<25).map { index in "item-\(index)" }
        let messages: [CodexHistoryMessage] = (20..<25).map { index in
            let role = index == 24 ? "assistant" : "system"
            let kind: MessageKind = index == 24 ? .message : .commandSummary
            let itemID: AgentItemID = "item-\(index)"
            return CodexHistoryMessage(
                id: "appserver:\(turnID):\(itemID)",
                role: role,
                kind: kind,
                content: "msg\(index)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                turnID: turnID,
                itemID: itemID,
                timelineOrdinal: Int64(index)
            )
        }

        let page = CodexAppServerSessionRuntime.paginateHistory(
            messages,
            before: nil,
            limit: 2,
            authoritativeCompletedTurnItems: [
                turnID: Set(allItemIDs)
            ]
        )

        XCTAssertEqual(page.messages.map { $0.itemID }, ["item-23", "item-24"])
        XCTAssertTrue(page.hasMoreBefore)
        XCTAssertEqual(page.authoritativeCompletedTurnItems[turnID], Set(allItemIDs))
    }

    func testPaginateHistoryReturnsAllWhenWithinLimitOrCursorMissing() {
        let messages = (0..<3).map { index in
            CodexHistoryMessage(id: "m\(index)", role: "user", content: "msg\(index)", createdAt: nil)
        }

        let full = CodexAppServerSessionRuntime.paginateHistory(messages, before: nil, limit: 10)
        XCTAssertEqual(full.messages.map(\.id), ["m0", "m1", "m2"])
        XCTAssertNil(full.previousCursor)
        XCTAssertFalse(full.hasMoreBefore)

        let missing = CodexAppServerSessionRuntime.paginateHistory(messages, before: "gone", limit: 2)
        XCTAssertTrue(missing.messages.isEmpty)
        XCTAssertNil(missing.previousCursor)
        XCTAssertFalse(missing.hasMoreBefore)
    }

    func testMessagePageResponseMapsToHistoryMessages() throws {
        let json = """
        {
          "page": {
            "session_id": "sess_1",
            "messages": [
              {
                "id": "msg_1",
                "session_id": "sess_1",
                "client_message_id": "client_1",
                "turn_id": "turn_1",
                "item_id": "item_1",
                "role": "user",
                "kind": "message",
                "content": "本地回显",
                "seq": 7,
                "revision": 1,
                "send_status": "confirmed",
                "is_timestamp_fallback": true
              }
            ],
            "next_cursor": "next",
            "previous_cursor": "prev",
            "has_more_before": true,
            "has_more_after": false,
            "snapshot_seq": 9
          }
        }
        """

        let response = try JSONDecoder().decode(MessagesResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.messages.count, 1)
        XCTAssertEqual(response.messages.first?.id, "msg_1")
        XCTAssertEqual(response.messages.first?.clientMessageID, "client_1")
        XCTAssertEqual(response.messages.first?.seq, 7)
        XCTAssertEqual(response.messages.first?.revision, 1)
        XCTAssertEqual(response.messages.first?.sendStatus, .confirmed)
        XCTAssertEqual(response.messages.first?.isTimestampFallback, true)
        XCTAssertEqual(response.nextCursor, "next")
        XCTAssertEqual(response.previousCursor, "prev")
        XCTAssertEqual(response.hasMoreBefore, true)
        XCTAssertEqual(response.snapshotSeq, 9)
        XCTAssertEqual(HistoryMessagesPage(response: response).snapshotSeq, 9)
    }

    func testSparseSessionRowsDecodeWithSafeDefaultsAndPaginationCursor() throws {
        let json = """
        {
          "rows": [
            {
              "id": "sess_sparse",
              "project_id": "proj_1"
            }
          ],
          "next_cursor": "cursor_next",
          "has_more": true
        }
        """

        let response = try JSONDecoder().decode(SessionsResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.rows.count, 1)
        XCTAssertEqual(response.rows.first?.title, L10n.text("ui.unnamed_session"))
        XCTAssertEqual(response.rows.first?.status, .unknown)
        XCTAssertEqual(response.rows.first?.source, "codex")
        XCTAssertEqual(response.rows.first?.revision, 0)
        XCTAssertEqual(response.sessions.first?.id, "sess_sparse")
        XCTAssertEqual(response.sessions.first?.projectID, "proj_1")
        XCTAssertEqual(response.sessions.first?.source, "codex")
        XCTAssertEqual(response.nextCursor, "cursor_next")
        XCTAssertEqual(response.hasMore, true)
    }

    func testMessagesResponsePreservesCursorAndClientMessageIDFallback() throws {
        let json = """
        {
          "messages": [
            {
              "role": "user",
              "content": "本地回显",
              "client_message_id": "client_echo_1"
            }
          ],
          "next_cursor": "newer",
          "previous_cursor": "older",
          "has_more_before": true
        }
        """

        let response = try JSONDecoder().decode(MessagesResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.messages.count, 1)
        XCTAssertEqual(response.messages.first?.id, "client_echo_1")
        XCTAssertEqual(response.messages.first?.clientMessageID, "client_echo_1")
        XCTAssertEqual(response.messages.first?.sendStatus, nil)
        XCTAssertEqual(response.nextCursor, "newer")
        XCTAssertEqual(response.previousCursor, "older")
        XCTAssertEqual(response.hasMoreBefore, true)
    }

    func testSparseMessagePageDefaultsToEmptyBoundedPage() throws {
        let response = try JSONDecoder().decode(
            MessagesResponse.self,
            from: Data(#"{"page":{"session_id":"sess_empty"}}"#.utf8)
        )

        XCTAssertEqual(response.page?.sessionID, "sess_empty")
        XCTAssertEqual(response.messages, [])
        XCTAssertEqual(response.page?.hasMoreBefore, false)
        XCTAssertEqual(response.page?.hasMoreAfter, false)
        XCTAssertEqual(response.nextCursor, nil)
        XCTAssertEqual(response.previousCursor, nil)
    }

    func testStructuredAssistantDeltaMergesByStableItemAndSeq() {
        let store = ConversationStore()
        let sessionID = "sess_structured"

        store.applyAssistantDelta(
            AgentDelta(text: "Hel", role: .assistant, kind: .message),
            metadata: AgentEventMetadata(
                seq: 1,
                sessionID: sessionID,
                turnID: "turn_1",
                itemID: "item_1",
                messageID: nil,
                clientMessageID: nil,
                revision: 1,
                createdAt: nil
            ),
            fallbackSessionID: sessionID
        )
        var messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.content, "Hel")

        store.applyAssistantDelta(
            AgentDelta(text: "lo", role: .assistant, kind: .message),
            metadata: AgentEventMetadata(
                seq: 2,
                sessionID: sessionID,
                turnID: "turn_1",
                itemID: "item_1",
                messageID: nil,
                clientMessageID: nil,
                revision: 2,
                createdAt: nil
            ),
            fallbackSessionID: sessionID
        )
        // 后续 delta 会先进入合并缓冲区，避免每个分片都触发 UI 刷新。
        messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.first?.content, "Hel")

        store.applyAssistantDelta(
            AgentDelta(text: "lo", role: .assistant, kind: .message),
            metadata: AgentEventMetadata(
                seq: 2,
                sessionID: sessionID,
                turnID: "turn_1",
                itemID: "item_1",
                messageID: nil,
                clientMessageID: nil,
                revision: 2,
                createdAt: nil
            ),
            fallbackSessionID: sessionID
        )
        store.markCurrentAssistantCompleted(
            metadata: AgentEventMetadata(
                seq: 3,
                sessionID: sessionID,
                turnID: "turn_1",
                itemID: "item_1",
                messageID: nil,
                clientMessageID: nil,
                revision: 3,
                createdAt: nil
            ),
            fallbackSessionID: sessionID
        )

        messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.role, .assistant)
        XCTAssertEqual(messages.first?.content, "Hello")
        XCTAssertEqual(messages.first?.stableID, "item_1")
        XCTAssertEqual(messages.first?.sendStatus, .confirmed)
    }

    func testStructuredAssistantDeltaFlushesBufferedTextOnTimer() async throws {
        let store = ConversationStore()
        let sessionID = "sess_delta_timer"

        store.applyAssistantDelta(
            AgentDelta(text: "A", role: .assistant, kind: .message),
            metadata: AgentEventMetadata(
                seq: 1,
                sessionID: sessionID,
                turnID: "turn_1",
                itemID: "item_1",
                messageID: nil,
                clientMessageID: nil,
                revision: 1,
                createdAt: nil
            ),
            fallbackSessionID: sessionID
        )
        store.applyAssistantDelta(
            AgentDelta(text: "B", role: .assistant, kind: .message),
            metadata: AgentEventMetadata(
                seq: 2,
                sessionID: sessionID,
                turnID: "turn_1",
                itemID: "item_1",
                messageID: nil,
                clientMessageID: nil,
                revision: 2,
                createdAt: nil
            ),
            fallbackSessionID: sessionID
        )
        XCTAssertEqual(store.messages(for: sessionID).first?.content, "A")

        try await waitForPendingAssistantDeltaFlush(in: store)

        XCTAssertEqual(store.messages(for: sessionID).first?.content, "AB")
        XCTAssertEqual(store.messages(for: sessionID).first?.revision, 2)
    }

    func testEmptyAssistantDeltaDoesNotCreateBubbleOrReserveRevision() throws {
        let store = ConversationStore()
        let sessionID = "sess_empty_delta"

        store.applyAssistantDelta(
            AgentDelta(text: "", role: .assistant, kind: .message),
            metadata: AgentEventMetadata(
                seq: 1,
                sessionID: sessionID,
                turnID: "turn_1",
                itemID: "item_empty",
                messageID: nil,
                clientMessageID: nil,
                revision: 2,
                createdAt: nil
            ),
            fallbackSessionID: sessionID
        )

        XCTAssertTrue(store.messages(for: sessionID).isEmpty)

        let completed = try JSONDecoder().decode(
            AgentMessage.self,
            from: Data("""
            {
              "id": "item_empty",
              "session_id": "\(sessionID)",
              "role": "assistant",
              "content": "最终回复",
              "revision": 2,
              "send_status": "confirmed"
            }
            """.utf8)
        )

        store.completeMessage(completed, metadata: .empty, fallbackSessionID: sessionID)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.content, "最终回复")
        XCTAssertEqual(messages.first?.revision, 2)
        XCTAssertEqual(messages.first?.sendStatus, .confirmed)
    }

    func testAssistantDeltaIgnoresOlderRevisionForSameStableItem() {
        let store = ConversationStore()
        let sessionID = "sess_revision"

        store.applyAssistantDelta(
            AgentDelta(text: "新版本", role: .assistant, kind: .message),
            metadata: AgentEventMetadata(
                seq: nil,
                sessionID: sessionID,
                turnID: "turn_1",
                itemID: "item_revision",
                messageID: nil,
                clientMessageID: nil,
                revision: 2,
                createdAt: nil
            ),
            fallbackSessionID: sessionID
        )
        store.applyAssistantDelta(
            AgentDelta(text: "旧版本", role: .assistant, kind: .message),
            metadata: AgentEventMetadata(
                seq: nil,
                sessionID: sessionID,
                turnID: "turn_1",
                itemID: "item_revision",
                messageID: nil,
                clientMessageID: nil,
                revision: 1,
                createdAt: nil
            ),
            fallbackSessionID: sessionID
        )

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.content, "新版本")
        XCTAssertEqual(messages.first?.revision, 2)
    }

    func testAssistantRevisionCacheIsScopedBySession() {
        let store = ConversationStore()

        store.applyAssistantDelta(
            AgentDelta(text: "A 会话", role: .assistant, kind: .message),
            metadata: AgentEventMetadata(
                seq: nil,
                sessionID: "sess_a",
                turnID: "turn_a",
                itemID: "item_shared",
                messageID: nil,
                clientMessageID: nil,
                revision: 2,
                createdAt: nil
            ),
            fallbackSessionID: "sess_a"
        )
        store.applyAssistantDelta(
            AgentDelta(text: "B 会话", role: .assistant, kind: .message),
            metadata: AgentEventMetadata(
                seq: nil,
                sessionID: "sess_b",
                turnID: "turn_b",
                itemID: "item_shared",
                messageID: nil,
                clientMessageID: nil,
                revision: 1,
                createdAt: nil
            ),
            fallbackSessionID: "sess_b"
        )

        let first = store.messages(for: "sess_a").first
        let second = store.messages(for: "sess_b").first
        XCTAssertEqual(first?.content, "A 会话")
        XCTAssertEqual(second?.content, "B 会话")
        XCTAssertNotEqual(first?.id, second?.id)
    }

    func testLocalEchoCanBeConfirmedByClientMessageID() {
        let store = ConversationStore()
        let sessionID = "sess_echo"
        let clientMessageID = "client-1"

        store.appendLocalUser("帮我跑测试", sessionID: sessionID, clientMessageID: clientMessageID, sendStatus: .sending)
        store.updateSendStatus(clientMessageID: clientMessageID, sessionID: sessionID, status: .sent)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.clientMessageID, clientMessageID)
        XCTAssertEqual(messages.first?.sendStatus, .sent)
    }

    func testAssistantDeltaAppendMaintainsStableMessageIndex() {
        let store = ConversationStore()
        let sessionID = "sess_assistant_index"
        let metadata = AgentEventMetadata(
            seq: nil,
            sessionID: sessionID,
            turnID: "turn_1",
            itemID: "item_1",
            messageID: "msg_assistant_1",
            clientMessageID: nil,
            revision: 1,
            createdAt: nil
        )

        store.applyAssistantDelta(
            AgentDelta(text: "第一段回复", role: .assistant, kind: .message),
            metadata: metadata,
            fallbackSessionID: sessionID
        )
        store.markCurrentAssistantCompleted(metadata: metadata, fallbackSessionID: sessionID)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.stableID, "msg_assistant_1")
        XCTAssertEqual(messages.first?.sendStatus, .confirmed)
        XCTAssertEqual(messages.first?.content, "第一段回复")
    }

    func testCompletedMessageConfirmsLocalEchoByClientMessageIDWithoutDuplicate() throws {
        let store = ConversationStore()
        let sessionID = "sess_confirm"
        let clientMessageID = "client-confirm-1"
        store.appendLocalUser("帮我跑测试", sessionID: sessionID, clientMessageID: clientMessageID, sendStatus: .sending)

        let message = try JSONDecoder().decode(
            AgentMessage.self,
            from: Data("""
            {
              "id": "client:\(clientMessageID)",
              "session_id": "\(sessionID)",
              "client_message_id": "\(clientMessageID)",
              "role": "user",
              "content": "帮我跑测试",
              "revision": 1,
              "send_status": "confirmed"
            }
            """.utf8)
        )

        store.completeMessage(message, metadata: .empty, fallbackSessionID: sessionID)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.clientMessageID, clientMessageID)
        XCTAssertEqual(messages.first?.stableID, "client:\(clientMessageID)")
        XCTAssertEqual(messages.first?.content, "帮我跑测试")
        XCTAssertEqual(messages.first?.sendStatus, .confirmed)
        XCTAssertEqual(messages.first?.revision, 1)
        let confirmedMessageID = try XCTUnwrap(messages.first?.id)

        let replay = try JSONDecoder().decode(
            AgentMessage.self,
            from: Data("""
            {
              "id": "client:\(clientMessageID)",
              "session_id": "\(sessionID)",
              "role": "user",
              "content": "帮我跑测试",
              "revision": 2,
              "send_status": "confirmed"
            }
            """.utf8)
        )
        store.completeMessage(replay, metadata: .empty, fallbackSessionID: sessionID)

        let replayedMessages = store.messages(for: sessionID)
        XCTAssertEqual(replayedMessages.count, 1)
        XCTAssertEqual(replayedMessages.first?.stableID, "client:\(clientMessageID)")
        XCTAssertEqual(replayedMessages.first?.revision, 2)
        XCTAssertEqual(replayedMessages.first?.id, confirmedMessageID)

        store.setHistory([
            CodexHistoryMessage(
                id: "client:\(clientMessageID)",
                role: "user",
                content: "帮我跑测试",
                createdAt: Date(timeIntervalSince1970: 2),
                clientMessageID: clientMessageID,
                revision: 2,
                sendStatus: .confirmed
            )
        ], sessionID: sessionID)

        let hydratedMessages = store.messages(for: sessionID)
        XCTAssertEqual(hydratedMessages.count, 1)
        XCTAssertEqual(hydratedMessages.first?.stableID, "client:\(clientMessageID)")
        XCTAssertEqual(hydratedMessages.first?.id, confirmedMessageID)
    }

    func testStructuredEventsDecodeFallbackPayloadsAndApprovalContext() throws {
        let decoder = JSONDecoder()

        let stringDelta = try decoder.decode(
            StructuredAgentEvent.self,
            from: Data(#"{"type":"assistant_delta","data":"字符串增量","seq":8,"session_id":"sess_1","message_id":"msg_1"}"#.utf8)
        )
        if case .assistantDelta(let delta, let meta) = stringDelta {
            XCTAssertEqual(delta.text, "字符串增量")
            XCTAssertEqual(meta.seq, 8)
            XCTAssertEqual(meta.messageID, "msg_1")
        } else {
            XCTFail("Expected assistant delta")
        }

        let approval = try decoder.decode(
            StructuredAgentEvent.self,
            from: Data(#"{"type":"approval_request","approval":{"id":"approval_1","title":"运行命令","body":"go test ./...","kind":"command","risk":"medium"},"seq":9,"session_id":"sess_1"}"#.utf8)
        )
        if case .approvalRequest(let request, let meta) = approval {
            XCTAssertEqual(request.id, "approval_1")
            XCTAssertEqual(request.kind, "command")
            XCTAssertEqual(request.risk, "medium")
            XCTAssertEqual(meta.seq, 9)
        } else {
            XCTFail("Expected approval request")
        }

        let resolved = try decoder.decode(
            StructuredAgentEvent.self,
            from: Data(#"{"type":"approval_resolved","seq":10,"session_id":"sess_1","item_id":"approval_1"}"#.utf8)
        )
        if case .approvalResolved(let meta) = resolved {
            XCTAssertEqual(meta.seq, 10)
            XCTAssertEqual(meta.sessionID, "sess_1")
            XCTAssertEqual(meta.itemID, "approval_1")
        } else {
            XCTFail("Expected approval resolved")
        }
    }

    func testAgentSessionDecodesStableServerIdentifiers() throws {
        let json = """
        {
          "id": "sess_1",
          "project_id": "proj_1",
          "project": "Mimi Remote",
          "dir": "/tmp/project",
          "title": "数据流测试",
          "status": "running",
          "source": "codex",
          "resume_id": "thread_1",
          "created_at": "2026-05-31T10:00:00Z",
          "updated_at": "2026-05-31T10:01:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let session = try decoder.decode(AgentSession.self, from: Data(json.utf8))

        XCTAssertEqual(session.id, "sess_1")
        XCTAssertEqual(session.projectID, "proj_1")
        XCTAssertEqual(session.resumeID, "thread_1")
        XCTAssertTrue(session.isRunning)
    }

    func testRecentWorkspaceStoreScopesByEndpointAndSupportsForget() {
        let first = AgentWorkspace(id: "proj_a", name: "Project A", path: "/tmp/proj-a")
        let second = AgentWorkspace(id: "proj_b", name: "Project B", path: "/tmp/proj-b")
        let store = makeRecentWorkspaceStore(workspaces: [], endpoint: "http://mac-a.local:8787")

        _ = store.upsert(first, endpoint: "http://mac-a.local:8787", openedAt: Date(timeIntervalSince1970: 10))
        _ = store.upsert(second, endpoint: "http://mac-b.local:8787", openedAt: Date(timeIntervalSince1970: 20))

        XCTAssertEqual(store.load(endpoint: "http://mac-a.local:8787").map(\.id), [first.id])
        XCTAssertEqual(store.load(endpoint: "http://mac-b.local:8787").map(\.id), [second.id])

        _ = store.forget(id: first.id, endpoint: "http://mac-a.local:8787")

        XCTAssertTrue(store.load(endpoint: "http://mac-a.local:8787").isEmpty)
        XCTAssertEqual(store.load(endpoint: "http://mac-b.local:8787").map(\.id), [second.id])
    }

    func testRecentWorkspaceStoreMigratesDuplicatePathToCanonicalWorkspaceID() throws {
        let suiteName = "RecentWorkspaceStoreTests.DuplicatePath.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let profileID = "mac-a"
        let canonical = AgentWorkspace(
            id: "ws_canonical",
            name: "chat-archive",
            path: "/Users/me/code/chat-archive",
            lastOpenedAt: Date(timeIntervalSince1970: 10)
        )
        let legacy = AgentWorkspace(
            id: "legacy-project-id",
            name: "旧名称",
            path: "/Users/me/code/chat-archive/",
            lastOpenedAt: Date(timeIntervalSince1970: 20)
        )
        var rawStorage = ProfileScopedStorage<[AgentWorkspace]>()
        rawStorage.byProfileID[profileID] = [legacy, canonical]
        defaults.set(
            try JSONEncoder().encode(rawStorage),
            forKey: "agentd.recentWorkspaces"
        )
        let store = RecentWorkspaceStore(defaults: defaults)

        let migration = store.loadReconciled(profileID: profileID)

        // ws_<path hash> 是 agentd 的稳定 identity，即使旧 project ID 时间更晚也不能反向降级。
        XCTAssertEqual(migration.workspaces.map(\.id), [canonical.id])
        XCTAssertEqual(
            migration.workspaces.first?.lastOpenedAt,
            legacy.lastOpenedAt,
            "合并后仍保留两条记录中的最近打开时间"
        )
        XCTAssertEqual(migration.replacedWorkspaceIDs, [legacy.id: canonical.id])
        XCTAssertEqual(store.load(profileID: profileID), migration.workspaces)
    }

    func testRecentWorkspaceStoreTreatsDarwinVarAliasAsSamePath() {
        let profileID = "mac-a"
        let store = makeRecentWorkspaceStore(workspaces: [], endpoint: "http://mac-a.local:8787")
        let legacy = AgentWorkspace(
            id: "legacy-var",
            name: "缓存",
            path: "/var/folders/example"
        )
        let canonical = AgentWorkspace(
            id: "ws_var",
            name: "缓存",
            path: "/private/var/folders/example"
        )

        store.save([legacy, canonical], profileID: profileID)

        let loaded = store.load(profileID: profileID)
        XCTAssertEqual(loaded.map(\.id), [canonical.id])
        XCTAssertEqual(loaded.first?.path, "/private/var/folders/example")
    }

    func testRecentWorkspaceStoreDoesNotMergeSameNameAtDifferentPaths() {
        let profileID = "mac-a"
        let store = makeRecentWorkspaceStore(workspaces: [], endpoint: "http://mac-a.local:8787")
        let first = AgentWorkspace(
            id: "ws_first",
            name: "chat-archive",
            path: "/Users/me/code/chat-archive"
        )
        let second = AgentWorkspace(
            id: "ws_second",
            name: "chat-archive",
            path: "/Users/me/archive/chat-archive"
        )

        store.save([first, second], profileID: profileID)

        XCTAssertEqual(Set(store.load(profileID: profileID).map(\.id)), [first.id, second.id])
    }

    func testSessionListPreferenceStoreScopesByEndpoint() {
        let store = makeSessionListPreferenceStore()
        store.save(
            SessionListPreferences(pinnedSessionIDs: ["session_a"], archivedSessionIDs: ["session_b"]),
            endpoint: "http://agent-a.local:8787"
        )
        store.save(
            SessionListPreferences(pinnedSessionIDs: ["session_c"], archivedSessionIDs: []),
            endpoint: "http://agent-b.local:8787"
        )

        XCTAssertEqual(store.load(endpoint: "http://agent-a.local:8787").pinnedSessionIDs, ["session_a"])
        XCTAssertEqual(store.load(endpoint: "http://agent-a.local:8787").archivedSessionIDs, ["session_b"])
        XCTAssertEqual(store.load(endpoint: "http://agent-b.local:8787").pinnedSessionIDs, ["session_c"])
        XCTAssertTrue(store.load(endpoint: "http://agent-b.local:8787").archivedSessionIDs.isEmpty)
    }

    func testSessionReminderStoreScopesByEndpoint() {
        let store = makeSessionReminderStore()
        let first = SessionReminder(
            sessionID: "session_a",
            title: "回看 A",
            fireAt: Date(timeIntervalSince1970: 3_600),
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let second = SessionReminder(
            sessionID: "session_b",
            title: "回看 B",
            fireAt: Date(timeIntervalSince1970: 7_200),
            createdAt: Date(timeIntervalSince1970: 2)
        )

        store.save([first.sessionID: first], endpoint: "http://agent-a.local:8787")
        store.save([second.sessionID: second], endpoint: "http://agent-b.local:8787")

        XCTAssertEqual(store.load(endpoint: "http://agent-a.local:8787"), [first.sessionID: first])
        XCTAssertEqual(store.load(endpoint: "http://agent-b.local:8787"), [second.sessionID: second])
    }

    func testProfileScopedStoresIsolateSameRemoteIDsAndRemoveOnlyTargetProfile() {
        let profileA = "profile-a"
        let profileB = "profile-b"
        let sharedSessionID = "shared-session"
        let workspaceStore = makeRecentWorkspaceStore(workspaces: [], endpoint: "http://legacy.local:8787")
        let preferenceStore = makeSessionListPreferenceStore()
        let controlStore = makeSessionControlStateStore()
        let reminderStore = makeSessionReminderStore()
        let workspaceA = AgentWorkspace(id: "shared-project", name: "Mac A", path: "/mac-a/project")
        let workspaceB = AgentWorkspace(id: "shared-project", name: "Mac B", path: "/mac-b/project")
        let reminderA = SessionReminder(
            sessionID: sharedSessionID,
            title: "Mac A 提醒",
            fireAt: Date(timeIntervalSince1970: 3_600),
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let reminderB = SessionReminder(
            sessionID: sharedSessionID,
            title: "Mac B 提醒",
            fireAt: Date(timeIntervalSince1970: 7_200),
            createdAt: Date(timeIntervalSince1970: 2)
        )

        workspaceStore.save([workspaceA], profileID: profileA)
        workspaceStore.save([workspaceB], profileID: profileB)
        preferenceStore.save(
            SessionListPreferences(pinnedSessionIDs: [sharedSessionID]),
            profileID: profileA
        )
        preferenceStore.save(
            SessionListPreferences(archivedSessionIDs: [sharedSessionID]),
            profileID: profileB
        )
        controlStore.save([sharedSessionID: .ipadOwned], profileID: profileA)
        controlStore.save([sharedSessionID: .observing], profileID: profileB)
        reminderStore.save([sharedSessionID: reminderA], profileID: profileA)
        reminderStore.save([sharedSessionID: reminderB], profileID: profileB)

        XCTAssertEqual(workspaceStore.load(profileID: profileA).first?.name, "Mac A")
        XCTAssertEqual(workspaceStore.load(profileID: profileB).first?.name, "Mac B")
        XCTAssertEqual(preferenceStore.load(profileID: profileA).pinnedSessionIDs, [sharedSessionID])
        XCTAssertEqual(preferenceStore.load(profileID: profileB).archivedSessionIDs, [sharedSessionID])
        XCTAssertEqual(controlStore.load(profileID: profileA)[sharedSessionID], .ipadOwned)
        XCTAssertEqual(controlStore.load(profileID: profileB)[sharedSessionID], .observing)
        XCTAssertEqual(reminderStore.load(profileID: profileA)[sharedSessionID], reminderA)
        XCTAssertEqual(reminderStore.load(profileID: profileB)[sharedSessionID], reminderB)

        workspaceStore.remove(profileID: profileA)
        preferenceStore.remove(profileID: profileA)
        controlStore.remove(profileID: profileA)
        reminderStore.remove(profileID: profileA)

        XCTAssertTrue(workspaceStore.load(profileID: profileA).isEmpty)
        XCTAssertTrue(preferenceStore.load(profileID: profileA).pinnedSessionIDs.isEmpty)
        XCTAssertTrue(controlStore.load(profileID: profileA).isEmpty)
        XCTAssertTrue(reminderStore.load(profileID: profileA).isEmpty)
        XCTAssertEqual(workspaceStore.load(profileID: profileB).first?.name, "Mac B")
        XCTAssertEqual(preferenceStore.load(profileID: profileB).archivedSessionIDs, [sharedSessionID])
        XCTAssertEqual(controlStore.load(profileID: profileB)[sharedSessionID], .observing)
        XCTAssertEqual(reminderStore.load(profileID: profileB)[sharedSessionID], reminderB)
    }

    func testProfileScopedStoresMigrateUniqueLegacyEndpointOnlyOnce() {
        let endpoint = "http://mac-a.local:8787"
        let profile = ConnectionProfile(
            id: "profile-a",
            displayName: "Mac A",
            endpoint: endpoint,
            lastSuccessfulAt: nil
        )
        let workspaceStore = makeRecentWorkspaceStore(workspaces: [], endpoint: endpoint)
        let preferenceStore = makeSessionListPreferenceStore()
        let controlStore = makeSessionControlStateStore()
        let reminderStore = makeSessionReminderStore()
        let workspace = AgentWorkspace(id: "legacy-project", name: "旧工作区", path: "/legacy/project")
        let reminder = SessionReminder(
            sessionID: "legacy-session",
            title: "旧提醒",
            fireAt: Date(timeIntervalSince1970: 7_200),
            createdAt: Date(timeIntervalSince1970: 1)
        )

        workspaceStore.save([workspace], endpoint: endpoint)
        preferenceStore.save(
            SessionListPreferences(pinnedSessionIDs: ["legacy-session"]),
            endpoint: endpoint
        )
        controlStore.save(["legacy-session": .takenOver], endpoint: endpoint)
        reminderStore.save(["legacy-session": reminder], endpoint: endpoint)

        XCTAssertEqual(
            workspaceStore.load(profileID: profile.id, legacyEndpoint: endpoint, profiles: [profile]),
            [workspace]
        )
        XCTAssertEqual(
            preferenceStore.load(profileID: profile.id, legacyEndpoint: endpoint, profiles: [profile])
                .pinnedSessionIDs,
            ["legacy-session"]
        )
        XCTAssertEqual(
            controlStore.load(profileID: profile.id, legacyEndpoint: endpoint, profiles: [profile]),
            ["legacy-session": .takenOver]
        )
        XCTAssertEqual(
            reminderStore.load(profileID: profile.id, legacyEndpoint: endpoint, profiles: [profile]),
            ["legacy-session": reminder]
        )

        // 修改旧 endpoint 数据后再次加载，Profile 副本不能被覆盖。
        workspaceStore.save([], endpoint: endpoint)
        preferenceStore.save(SessionListPreferences(), endpoint: endpoint)
        controlStore.save([:], endpoint: endpoint)
        reminderStore.save([:], endpoint: endpoint)

        XCTAssertEqual(workspaceStore.load(profileID: profile.id), [workspace])
        XCTAssertEqual(preferenceStore.load(profileID: profile.id).pinnedSessionIDs, ["legacy-session"])
        XCTAssertEqual(controlStore.load(profileID: profile.id), ["legacy-session": .takenOver])
        XCTAssertEqual(reminderStore.load(profileID: profile.id), ["legacy-session": reminder])
    }

    func testProfileScopedMigrationSkipsAmbiguousEndpointUntilUnique() {
        let endpoint = "http://shared-mac.local:8787"
        let first = ConnectionProfile(
            id: "profile-a",
            displayName: "Mac A",
            endpoint: endpoint,
            lastSuccessfulAt: nil
        )
        let second = ConnectionProfile(
            id: "profile-b",
            displayName: "Mac B",
            endpoint: endpoint + "/",
            lastSuccessfulAt: nil
        )
        let store = makeSessionListPreferenceStore()
        store.save(
            SessionListPreferences(pinnedSessionIDs: ["legacy-session"]),
            endpoint: endpoint
        )

        let ambiguous = store.load(
            profileID: first.id,
            legacyEndpoint: endpoint,
            profiles: [first, second]
        )

        XCTAssertTrue(ambiguous.pinnedSessionIDs.isEmpty)
        XCTAssertTrue(store.load(profileID: first.id).pinnedSessionIDs.isEmpty)

        let migratedAfterResolution = store.load(
            profileID: first.id,
            legacyEndpoint: endpoint,
            profiles: [first]
        )
        XCTAssertEqual(migratedAfterResolution.pinnedSessionIDs, ["legacy-session"])
    }

    func testDeletingAmbiguousProfileImmediatelyMigratesCurrentRecentWorkspaces() async throws {
        let suiteName = "RecentWorkspaceStoreTests.DeleteAmbiguousProfile.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let endpoint = "http://shared-mac.local:8787"
        let current = ConnectionProfile(
            id: "mac-a",
            displayName: "Mac A",
            endpoint: endpoint,
            lastSuccessfulAt: nil
        )
        let duplicate = ConnectionProfile(
            id: "mac-b",
            displayName: "Mac B",
            endpoint: endpoint + "/",
            lastSuccessfulAt: nil
        )
        defaults.set(
            try JSONEncoder().encode([current, duplicate]),
            forKey: "agentd.connectionProfiles.v1"
        )
        defaults.set(current.id, forKey: "agentd.activeConnectionProfileID.v1")
        defaults.set(current.endpoint, forKey: "agentd.endpoint")

        let keychain = TestKeychainOperations()
        keychain.setData(Data("token-a".utf8), account: "agentd-profile.mac-a")
        keychain.setData(Data("token-b".utf8), account: "agentd-profile.mac-b")
        let appStore = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: keychain)
        )
        let workspace = AgentWorkspace(
            id: "legacy-project",
            name: "旧工作区",
            path: "/legacy/project"
        )
        let recentWorkspaceStore = makeRecentWorkspaceStore(
            workspaces: [workspace],
            endpoint: endpoint
        )
        let sessionStore = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: recentWorkspaceStore,
            clientFactory: {
                MockSessionStoreClient(projects: [], sessions: [])
            }
        )

        sessionStore.reloadRecentWorkspaces()
        XCTAssertTrue(sessionStore.recentWorkspaces.isEmpty)

        try await sessionStore.deleteConnectionProfile(id: duplicate.id)

        XCTAssertEqual(sessionStore.recentWorkspaces.map(\.id), [workspace.id])
        XCTAssertEqual(recentWorkspaceStore.load(profileID: current.id).map(\.id), [workspace.id])
    }

}

private final class RecordingVoiceAudioSessionBackend: VoiceAudioSessionBackend, @unchecked Sendable {
    enum Operation: Equatable {
        case prepare
        case activate
        case deactivate
    }

    enum TestError: Error, Equatable {
        case requestedFailure(Operation)
    }

    private let lock = NSLock()
    private let failingOperation: Operation?
    private var storedOperations: [Operation] = []
    private var storedWasCalledOnMainThread = false

    init(failingOperation: Operation? = nil) {
        self.failingOperation = failingOperation
    }

    var operations: [Operation] {
        lock.withLock { storedOperations }
    }

    var wasCalledOnMainThread: Bool {
        lock.withLock { storedWasCalledOnMainThread }
    }

    func prepareForRecording() throws {
        try record(.prepare)
    }

    func activateForRecording() throws {
        try record(.activate)
    }

    func deactivateRecording() throws {
        try record(.deactivate)
    }

    private func record(_ operation: Operation) throws {
        try lock.withLock {
            storedOperations.append(operation)
            storedWasCalledOnMainThread = storedWasCalledOnMainThread || Thread.isMainThread
            if failingOperation == operation {
                throw TestError.requestedFailure(operation)
            }
        }
    }
}

@MainActor
private func hostVoiceMicButton(
    isPreparing: Bool,
    isRecording: Bool,
    isTranscribing: Bool
) -> UIHostingController<AnyView> {
    let themeStore = ThemeStore()
    let view = VoiceMicButton(
        isPreparing: isPreparing,
        isRecording: isRecording,
        isTranscribing: isTranscribing,
        usesRealtimeTranscription: false,
        onTap: {}
    )
    .environmentObject(themeStore)
    .frame(width: 44, height: 44)

    return UIHostingController(rootView: AnyView(view))
}
