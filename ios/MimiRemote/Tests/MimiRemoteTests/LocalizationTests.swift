import XCTest
@testable import MimiRemote

final class LocalizationTests: XCTestCase {
    func testRuntimeCatalogUsesStoredEnglishLanguage() {
        // 日常核心回归固定 zh-Hans；显式写入 App 语言可在同一 XCTest 进程
        // 验证英文资源确实被打包且运行时可选择，不必为每个 PR 再启动一次 Simulator。
        let defaults = UserDefaults.standard
        let hadStoredLanguage = defaults.object(forKey: AppLanguage.preferenceKey) != nil
        let previousLanguage = defaults.string(forKey: AppLanguage.preferenceKey)
        defaults.set(AppLanguage.english.rawValue, forKey: AppLanguage.preferenceKey)
        defer {
            if hadStoredLanguage {
                defaults.set(previousLanguage, forKey: AppLanguage.preferenceKey)
            } else {
                defaults.removeObject(forKey: AppLanguage.preferenceKey)
            }
        }

        XCTAssertEqual(AppLanguage.stored(), .english)
        XCTAssertEqual(L10n.text("ui.settings"), "Settings")
        XCTAssertEqual(
            L10n.format("ui.awaiting_approval_value_value", "Review diff", " · Low risk"),
            "Awaiting approval: Review diff · Low risk"
        )
    }

    func testObjectFormatterSupportsIntegersAndMultipleArguments() {
        XCTAssertEqual(
            L10n.formatTemplate("%@ has %@ messages", arguments: [42, 3]),
            "42 has 3 messages"
        )
    }

    func testObjectFormatterDoesNotInterpretPlaceholderInsideArgument() {
        XCTAssertEqual(
            L10n.formatTemplate("Message: %@", arguments: ["literal %@ text"]),
            "Message: literal %@ text"
        )
    }

    func testObjectFormatterSupportsTranslatorControlledPosition() {
        XCTAssertEqual(
            L10n.formatTemplate("Second: %2$@; first: %1$@", arguments: ["one", "two"]),
            "Second: two; first: one"
        )
    }

    func testSidebarOverflowCountUsesSupportedObjectPlaceholder() {
        let english = L10n.text("ui.more_sessions_count", language: .english)
        let simplifiedChinese = L10n.text("ui.more_sessions_count", language: .simplifiedChinese)

        // L10n.formatTemplate 会先把参数安全地转换成 NSString，因此目录只能使用 %@。
        // 若误写成 %lld，运行时会把对象地址当作数量展示，出现巨大的正数或负数。
        XCTAssertEqual(L10n.formatTemplate(english, arguments: [28]), "28 more")
        XCTAssertEqual(L10n.formatTemplate(simplifiedChinese, arguments: [28]), "还有 28 条")
    }

    func testExplicitLanguageLookupSwitchesCatalogWithoutRestart() {
        XCTAssertEqual(L10n.text("ui.settings", language: .english), "Settings")
        XCTAssertEqual(L10n.text("ui.settings", language: .simplifiedChinese), "设置")
    }

    func testToolActivitySemanticLabelsAreLocalized() {
        let expectedValues: [(String, String, String)] = [
            ("ui.query_linear_issues", "Query Linear issues", "查询 Linear Issue"),
            ("ui.read_issue_comments", "Read issue comments", "读取 Issue 评论"),
            ("ui.update_linear_issue", "Update Linear issue", "更新 Linear Issue"),
            ("ui.query_task_list", "Query task list", "查询任务列表"),
            ("ui.start_independent_task", "Start independent task", "启动独立任务"),
            ("ui.resume_independent_task", "Resume independent task", "恢复独立任务"),
            ("ui.wait_for_task_results", "Wait for task results", "等待任务结果"),
            ("ui.start_subagent", "Start subagent", "启动子 Agent"),
            ("ui.timed_out_status", "Timed out", "已超时"),
            ("ui.interrupted_status", "Interrupted", "已中断"),
        ]

        for (key, english, simplifiedChinese) in expectedValues {
            XCTAssertEqual(L10n.text(key, language: .english), english)
            XCTAssertEqual(L10n.text(key, language: .simplifiedChinese), simplifiedChinese)
        }
    }

    func testSettingsInformationArchitectureLabelsAreLocalized() {
        let expectedValues: [(String, String, String)] = [
            ("ui.me", "Me", "我的"),
            ("ui.token_usage", "Token usage", "Token 使用量"),
            ("ui.current_remaining", "Current Remaining", "当前剩余"),
            ("ui.token_activity", "Token Activity", "Token 活动"),
            ("ui.my_preferences", "My Preferences", "我的偏好设置"),
            ("ui.more", "More", "更多"),
            ("ui.experimental_features", "Experimental Features", "实验功能"),
            ("ui.tailcat_experiment", "Tailcat", "Tailcat"),
            ("ui.managed_subscription_title", "Mimi Managed Connection", "Mimi 托管连接"),
            ("ui.custom_tailcat", "Self-hosted Tailcat", "自建 Tailcat"),
            ("ui.personalization", "Appearance & Personalization", "外观与个性化"),
            ("ui.advanced_and_development", "Advanced & Development", "高级与开发"),
            ("ui.about_and_legal", "About & Legal", "关于与法律")
        ]

        for (key, english, simplifiedChinese) in expectedValues {
            XCTAssertEqual(L10n.text(key, language: .english), english)
            XCTAssertEqual(L10n.text(key, language: .simplifiedChinese), simplifiedChinese)
        }
    }

    func testActiveWriterConflictExplainsRecoveryAction() {
        XCTAssertEqual(
            L10n.text("ui.codex_active_writer_conflict", language: .english),
            "Close the session in the other app before continuing here."
        )
        XCTAssertEqual(
            L10n.text("ui.codex_active_writer_conflict", language: .simplifiedChinese),
            "请先在那边关闭会话，才能在这里继续。"
        )
        XCTAssertEqual(L10n.text("ui.codex_active_writer_conflict_title", language: .english), "Open in another app")
        XCTAssertEqual(L10n.text("ui.codex_active_writer_conflict_title", language: .simplifiedChinese), "已在另一个应用中打开")
        let writerConflictForkValues: [(String, String, String)] = [
            (
                "ui.writer_conflict_fork_idle_explanation",
                "Copy this session to continue here; the original stays unchanged.",
                "复制为新会话后，可在这里继续；原会话保持不变。"
            ),
            (
                "ui.writer_conflict_fork_running_explanation",
                "The copy will end at the previous finished turn; the current Desktop response won’t be included.",
                "将复制到上一轮结束的位置；Desktop 当前回复不会带入。"
            ),
            (
                "ui.writer_conflict_fork_no_terminal_turn",
                "There isn’t a finished turn to copy yet. Wait for the current Desktop response to finish.",
                "当前还没有可复制的完整回合。请等待 Desktop 当前回复完成。"
            ),
            ("ui.writer_conflict_fork_continue", "Branch to new chat", "分支到新聊天"),
            ("ui.writer_conflict_fork_checking", "Checking…", "正在检查…"),
            ("ui.writer_conflict_fork_copying", "Branching…", "正在创建分支…"),
            (
                "ui.writer_conflict_retry_refresh_failed",
                "Couldn’t load the latest messages. Try again.",
                "未能加载最新消息，请重试。"
            ),
            ("ui.writer_conflict_fork_recheck", "Check again", "重新检查"),
            (
                "ui.retry_writer_access",
                "Reload messages and retry writer access",
                "重新加载消息并重试写入权限"
            )
        ]
        for (key, english, simplifiedChinese) in writerConflictForkValues {
            XCTAssertEqual(L10n.text(key, language: .english), english)
            XCTAssertEqual(L10n.text(key, language: .simplifiedChinese), simplifiedChinese)
        }
        XCTAssertEqual(L10n.text("ui.load_full_history", language: .english), "Load full content")
        XCTAssertEqual(L10n.text("ui.load_full_history", language: .simplifiedChinese), "加载完整内容")
        XCTAssertEqual(
            L10n.text("ui.this_session_contains_large_images_or_tool_output", language: .simplifiedChinese),
            "已显示最近记录。较大的图片和工具输出暂未加载。"
        )
    }

    func testStandaloneEnglishLabelsStartWithCapitalLetter() {
        // #465：标签栏、会话状态与审批卡按钮独立显示，英文首字母必须大写，
        // 与同一行的 Devices、Processing、Allow Once 保持一致。
        let expectedValues: [(String, String)] = [
            ("ui.session", "Session"),
            ("ui.workspace", "Workspace"),
            ("ui.devices", "Devices"),
            ("ui.me", "Me"),
            ("ui.ended", "Ended"),
            ("ui.processing", "Processing"),
            ("ui.reject", "Reject"),
            ("ui.approve_once", "Approve Once"),
            ("ui.allow_once", "Allow Once")
        ]

        for (key, english) in expectedValues {
            XCTAssertEqual(L10n.text(key, language: .english), english, key)
        }
        // 拼进句子的片段保持小写，例如「This closes the idle session in another Claude Code process…」。
        XCTAssertEqual(L10n.text("ui.claude_owner_other", language: .english), "another Claude Code process")
    }

    func testSessionRowStatefulActionLabelsAreLocalized() {
        let expectedValues: [(String, String, String)] = [
            ("ui.pin_to_top", "Pin to Top", "置顶"),
            ("ui.unpin", "Unpin", "取消置顶"),
            ("ui.mark_as_read", "Mark as Read", "标记为已读"),
            ("ui.mark_as_unread", "Mark as Unread", "标记为未读"),
            ("ui.archive", "Archive", "归档"),
            ("ui.unarchive", "Unarchive", "取消归档")
        ]

        for (key, english, simplifiedChinese) in expectedValues {
            XCTAssertEqual(L10n.text(key, language: .english), english)
            XCTAssertEqual(L10n.text(key, language: .simplifiedChinese), simplifiedChinese)
        }
    }

    func testSettingsLayoutMetricsUseOneVisualSystem() {
        XCTAssertEqual(SettingsLayoutMetrics.standardRowHeight, 52)
        XCTAssertEqual(SettingsLayoutMetrics.accessibilityRowHeight, 76)
        XCTAssertEqual(SettingsLayoutMetrics.iconSlot, 24)
        XCTAssertEqual(SettingsLayoutMetrics.iconSpacing, 12)
        // 会话行前导槽与设置行图标槽同宽；设置行在卡片里，图标到文字比会话行多留 4pt（#615）。
        XCTAssertEqual(SessionIndexRowDensity.compact.stateGutterWidth, SettingsLayoutMetrics.iconSlot)
        XCTAssertEqual(SettingsLayoutMetrics.symbolPointSize, 18)
    }

    func testTokenCountFormatterUsesProductCompactUnits() {
        XCTAssertEqual(
            TokenCountFormatter.string(50_160_000_000, language: .simplifiedChinese),
            "501.6亿"
        )
        XCTAssertEqual(
            TokenCountFormatter.string(50_160_000_000, language: .english),
            "50.2B"
        )
        XCTAssertEqual(TokenCountFormatter.string(nil, language: .english), "—")
    }

    func testTokenActivityCalendarAggregatesAndRejectsInvalidDays() throws {
        let calendar = TokenActivityCalendar.utcCalendar
        let endingAt = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 7, day: 30))
        )
        let weeks = TokenActivityCalendar.weeks(
            buckets: [
                AccountTokenUsageDailyBucket(startDate: "2026-07-30", tokens: 100),
                AccountTokenUsageDailyBucket(startDate: "2026-07-30", tokens: 50),
                AccountTokenUsageDailyBucket(startDate: "2026-07-29", tokens: -20),
                AccountTokenUsageDailyBucket(startDate: "2026-02-30", tokens: 999),
                AccountTokenUsageDailyBucket(startDate: "2026-08-01", tokens: 999)
            ],
            endingAt: endingAt
        )

        XCTAssertEqual(weeks.count, 53)
        XCTAssertTrue(weeks.allSatisfy { $0.days.count == 7 })
        let activeDay = try XCTUnwrap(
            weeks.flatMap(\.days).first {
                calendar.isDate($0.date, inSameDayAs: endingAt)
            }
        )
        XCTAssertEqual(activeDay.tokens, 150)
        XCTAssertGreaterThan(activeDay.intensity, 0)
        XCTAssertNil(TokenActivityCalendar.date(from: "2026-02-30"))
        XCTAssertEqual(
            weeks.flatMap(\.days).filter { $0.tokens > 0 }.count,
            1,
            "未来日、非法日期与负数都不能进入活动统计"
        )
    }

    func testTokenActivityCalendarSaturatesDuplicateBucketOverflow() throws {
        let calendar = TokenActivityCalendar.utcCalendar
        let endingAt = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 7, day: 30))
        )
        let weeks = TokenActivityCalendar.weeks(
            buckets: [
                AccountTokenUsageDailyBucket(startDate: "2026-07-30", tokens: .max),
                AccountTokenUsageDailyBucket(startDate: "2026-07-30", tokens: 1)
            ],
            endingAt: endingAt
        )
        let activeDay = try XCTUnwrap(
            weeks.flatMap(\.days).first {
                calendar.isDate($0.date, inSameDayAs: endingAt)
            }
        )

        XCTAssertEqual(activeDay.tokens, .max)
        XCTAssertEqual(activeDay.intensity, 4)
    }

    func testTokenActivityGridAdaptsRecentWeeksWithoutShrinkingCells() {
        XCTAssertEqual(
            TokenActivityGridMetrics.weekCount(
                availableWidth: 0,
                isAccessibilitySize: false
            ),
            0
        )
        XCTAssertEqual(
            TokenActivityGridMetrics.weekCount(
                availableWidth: -.infinity,
                isAccessibilitySize: true
            ),
            0
        )
        XCTAssertEqual(
            TokenActivityGridMetrics.cellSize(availableWidth: 0, weekCount: 6),
            0
        )
        XCTAssertEqual(
            TokenActivityGridMetrics.weekCount(
                availableWidth: 38,
                isAccessibilitySize: false
            ),
            5,
            "极窄布局应减少周数，不能由六周最小值反向撑宽"
        )
        let narrowWeekCount = TokenActivityGridMetrics.weekCount(
            availableWidth: 38,
            isAccessibilitySize: false
        )
        let narrowCellSize = TokenActivityGridMetrics.cellSize(
            availableWidth: 38,
            weekCount: narrowWeekCount
        )
        XCTAssertLessThanOrEqual(
            narrowCellSize * CGFloat(narrowWeekCount)
                + TokenActivityGridMetrics.spacing * CGFloat(narrowWeekCount - 1),
            38
        )
        XCTAssertEqual(
            TokenActivityGridMetrics.weekCount(
                availableWidth: 130,
                isAccessibilitySize: false
            ),
            14
        )
        XCTAssertEqual(
            TokenActivityGridMetrics.weekCount(
                availableWidth: 130,
                isAccessibilitySize: true
            ),
            13
        )
        XCTAssertEqual(
            TokenActivityGridMetrics.weekCount(
                availableWidth: 600,
                isAccessibilitySize: false
            ),
            53
        )
        XCTAssertGreaterThanOrEqual(
            TokenActivityGridMetrics.cellSize(availableWidth: 130, weekCount: 14),
            TokenActivityGridMetrics.minimumCellSize
        )
    }

    func testTokenActivityCalendarUsesRequestedRecentWindowAndSparseMonthLabels() throws {
        let calendar = TokenActivityCalendar.utcCalendar
        let endingAt = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 7, day: 30))
        )
        let weeks = TokenActivityCalendar.weeks(
            buckets: [],
            endingAt: endingAt,
            weekCount: 16
        )
        let labels = TokenActivityCalendar.monthLabels(for: weeks)

        XCTAssertEqual(weeks.count, 16)
        XCTAssertEqual(labels.first?.weekIndex, 0)
        XCTAssertTrue(
            zip(labels, labels.dropFirst()).allSatisfy { pair in
                pair.1.weekIndex - pair.0.weekIndex >= 4
            },
            "月份标签至少相隔四周，避免窄屏重叠"
        )
        XCTAssertTrue(
            labels.dropFirst().allSatisfy { weeks.count - $0.weekIndex >= 3 },
            "末端至少保留三周宽度，避免月份文字被右边界裁切"
        )
    }

    func testStoredLanguageFallsBackToSystemForUnknownValue() {
        let suiteName = "LocalizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(AppLanguage.stored(in: defaults), .system)
        defaults.set(AppLanguage.english.rawValue, forKey: AppLanguage.preferenceKey)
        XCTAssertEqual(AppLanguage.stored(in: defaults), .english)
        defaults.set("unsupported", forKey: AppLanguage.preferenceKey)
        XCTAssertEqual(AppLanguage.stored(in: defaults), .system)
    }

    func testVoiceInputProviderDefaultsToAppleAndPreservesKnownSelection() {
        let suiteName = "VoiceInputProviderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(VoiceInputProvider.stored(in: defaults, supportsAppleSpeech: true), .apple)
        XCTAssertEqual(VoiceInputProvider.stored(in: defaults, supportsAppleSpeech: false), .codex)
        defaults.set(VoiceInputProvider.apple.rawValue, forKey: VoiceInputProvider.storageKey)
        XCTAssertEqual(VoiceInputProvider.stored(in: defaults, supportsAppleSpeech: true), .apple)
        defaults.set(VoiceInputProvider.codex.rawValue, forKey: VoiceInputProvider.storageKey)
        XCTAssertEqual(VoiceInputProvider.stored(in: defaults, supportsAppleSpeech: true), .codex)
        defaults.set("future-provider", forKey: VoiceInputProvider.storageKey)
        XCTAssertEqual(VoiceInputProvider.stored(in: defaults, supportsAppleSpeech: true), .apple)
        XCTAssertEqual(VoiceInputProvider.stored(in: defaults, supportsAppleSpeech: false), .codex)
    }

    func testVoiceInputProviderAvailabilityFiltersAppleOnUnsupportedSystems() {
        XCTAssertEqual(
            VoiceInputProvider.availableProviders(supportsAppleSpeech: false),
            [.codex]
        )
        XCTAssertEqual(
            VoiceInputProvider.availableProviders(supportsAppleSpeech: true),
            [.codex, .apple]
        )
    }

    func testSavedAppleVoiceProviderFallsBackWithoutOverwritingStoredValue() {
        let suiteName = "VoiceInputProviderCompatibilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(VoiceInputProvider.apple.rawValue, forKey: VoiceInputProvider.storageKey)

        XCTAssertEqual(
            VoiceInputProvider.stored(in: defaults, supportsAppleSpeech: false),
            .codex
        )
        XCTAssertEqual(
            defaults.string(forKey: VoiceInputProvider.storageKey),
            VoiceInputProvider.apple.rawValue,
            "旧系统回退时不应清除升级后可恢复的历史偏好"
        )
        XCTAssertEqual(
            VoiceInputProvider.stored(in: defaults, supportsAppleSpeech: true),
            .apple
        )
    }

    func testVoiceInputProvidersExposeDistinctNativeSystemIcons() {
        XCTAssertEqual(VoiceInputProvider.codex.icon, .system("waveform"))
        XCTAssertEqual(VoiceInputProvider.apple.icon, .system("siri"))
    }

    func testCodexVoiceInputDescriptionExplainsPostRecordingTranscription() {
        XCTAssertEqual(
            L10n.text("ui.codex_voice_input_description", language: .simplifiedChinese),
            "使用 Codex 内置语音能力 · 录音结束后转写"
        )
        XCTAssertEqual(
            L10n.text("ui.codex_voice_input_description", language: .english),
            "Uses Codex built-in voice capability · Transcribes after recording"
        )
    }

    func testLanguageSettingsSummaryKeepsBothSelectionsVisible() {
        XCTAssertEqual(
            L10n.formatTemplate(
                L10n.text("ui.language_settings_summary", language: .english),
                arguments: ["System Default", "Codex"]
            ),
            "System Default · Codex"
        )
        XCTAssertEqual(
            L10n.formatTemplate(
                L10n.text("ui.language_settings_summary", language: .simplifiedChinese),
                arguments: ["跟随系统", "设备端"]
            ),
            "跟随系统 · 设备端"
        )
    }

    /// 连接的电脑可能是 Windows 或 Linux：泛指主机的连接、配对、诊断、上传和接管文案
    /// 不能写成 Mac 或「Mimi Mac 助手」，中英文都要一致（#673）。
    func testHostNeutralCopyDoesNotAssumeMac() {
        let keys = [
            "ui.a_secure_channel_is_being_established_content_appears",
            "ui.access_code_verification_failed_please_pair_again_in",
            "ui.automatic_retries_stopped_existing_sessions_remain_please_rescan",
            "ui.check_iphone_ipad_to_mac_assistant_authentication_gateway",
            "ui.check_the_mac_assistant_codex_cli_app_server",
            "ui.claude_code_login_expired_recovery",
            "ui.claude_login_command_copied",
            "ui.click_recheck_to_get_status_from_mac_assistant",
            "ui.codex_saves_this_choice_on_the_mac",
            "ui.connecting_to_your_mac",
            "ui.current_mac_named",
            "ui.current_mac_version_does_not_support_file_upload",
            "ui.diagnostic_request_failed_http_value_please_check_mac",
            "ui.doctor_fix_generic",
            "ui.file_preview_path_outside_scope",
            "ui.file_upload_capability_negotiation_failed",
            "ui.file_upload_dependency_unavailable_on_current_mac",
            "ui.file_upload_disabled_on_current_mac",
            "ui.file_upload_host_changed_select_again",
            "ui.if_a_permission_request_pops_up_allow_camera",
            "ui.mac_assistant_connected",
            "ui.mac_assistant_returned_an_unrecognized_network_response",
            "ui.mac_connection",
            "ui.mac_devices",
            "ui.mac_name",
            "ui.mac_returned_raw_diagnostic_details",
            "ui.managed_connection_fallback_notice",
            "ui.managed_devices_connect_mac",
            "ui.managed_devices_connecting",
            "ui.managed_devices_connection",
            "ui.managed_devices_mac",
            "ui.managed_devices_pairing_conflict",
            "ui.managed_devices_qr_required",
            "ui.managed_devices_remove_message",
            "ui.managed_devices_rescan_notice",
            "ui.mimi_doesn_t_have_camera_permissions_and_can",
            "ui.not_connected_to_mac_yet",
            "ui.paste_connection_info_hint",
            "ui.please_check_mac_assistant_and_network_connections",
            "ui.please_install_and_enable_the_codex_plug_in",
            "ui.prepared_connection_mismatch",
            "ui.public_network_http_value_will_transmit_the_access",
            "ui.push_approval_result_unknown",
            "ui.reading_the_workspace_list_from_this_mac",
            "ui.reference_the_installed_codex_plug_in_on_mac",
            "ui.removing_a_directory_only_removes_it_from_the_workspace",
            "ui.rename_mac",
            "ui.request_doctor_diagnosis_results_from_mac_assistant",
            "ui.session_owned_elsewhere_message",
            "ui.session_owned_elsewhere_title",
            "ui.start_the_assistant_and_display_the_qr_code",
            "ui.tailcat_needs_address",
            "ui.tailcat_pairing_help",
            "ui.take_over_claude_failed_respawned",
            "ui.take_over_claude_failed_signal",
            "ui.take_over_claude_failed_timeout",
            "ui.take_over_claude_failed_unverified",
            "ui.take_over_claude_session_confirm_action",
            "ui.take_over_claude_session_confirm_message",
            "ui.take_over_claude_state_unknown",
            "ui.take_over_claude_upgrade_required",
            "ui.take_over_claude_wait_until_idle",
            "ui.the_access_code_has_expired_and_automatic_retries",
            "ui.the_code_scan_has_been_cancelled_please_scan",
            "ui.the_connection_address_is_invalid_please_enter_the",
            "ui.the_connection_credentials_have_been_saved_safely_but",
            "ui.the_connection_file_cannot_be_found_for_this",
            "ui.the_connection_was_not_completed_please_confirm_that",
            "ui.the_current_agentd_version_does_not_support_clean",
            "ui.the_current_device_restricts_camera_access_and_cannot",
            "ui.the_local_queue_does_not_belong_to_the",
            "ui.the_mac_assistant_address_is_invalid_please_return",
            "ui.the_notification_comes_from_another_mac_please_switch",
            "ui.the_public_http_address_value_has_been_blocked",
            "ui.the_session_corresponding_to_the_notification_cannot_be",
            "ui.the_session_corresponding_to_the_notification_is_temporarily",
            "ui.there_are_currently_no_connection_credentials_available_please",
            "ui.this_notification_comes_from_another_mac_please_switch",
            "ui.timeout_connecting_to_mac_assistant_please_confirm_that",
            "ui.token_activity_unavailable",
            "ui.unable_to_connect_to_mac_assistant_please_confirm",
            "ui.unconfirmed_send_after_mac_switch",
            "ui.verifying_mac_connection",
            "ui.waiting_for_mac_assistant_to_return_check_results",
            "ui.workspaces_on_this_mac_appear_as_soon_as",
            "ui.pairing_qr_expired_refresh_windows",
            "ui.pairing_qr_expired_refresh_linux"
        ]

        for key in keys {
            for language in [AppLanguage.english, .simplifiedChinese] {
                let value = L10n.text(key, language: language)
                XCTAssertNotEqual(value, key, "\(key) 缺少 \(language.rawValue) 文案")
                XCTAssertFalse(value.contains("Mac"), "\(key) [\(language.rawValue)] 仍指向 Mac：\(value)")
            }
        }
    }

    /// 二维码过期指引按电脑平台给入口；平台未知时同时覆盖 Mac、Windows 和命令行安装（#673）。
    func testPairingQRCodeExpiredGuidanceFollowsHostPlatform() {
        let keysByPlatform: [(HostPlatform, String)] = [
            (.apple, "ui.the_pairing_qr_code_has_expired_please_re"),
            (.windows, "ui.pairing_qr_expired_refresh_windows"),
            (.linux, "ui.pairing_qr_expired_refresh_linux"),
            (.unknown, "ui.pairing_qr_expired_refresh_generic")
        ]
        for (platform, key) in keysByPlatform {
            XCTAssertEqual(platform.pairingQRCodeExpiredGuidance, L10n.text(key))
            XCTAssertTrue(HostPlatform.isPairingQRCodeExpiredGuidance(platform.pairingQRCodeExpiredGuidance))
        }
        XCTAssertFalse(HostPlatform.isPairingQRCodeExpiredGuidance(L10n.text("ui.the_pairing_qr_code_has_expired")))

        let mac = "ui.the_pairing_qr_code_has_expired_please_re"
        XCTAssertTrue(L10n.text(mac, language: .simplifiedChinese).contains("菜单栏"))
        XCTAssertTrue(L10n.text(mac, language: .english).contains("menu bar"))

        let windows = "ui.pairing_qr_expired_refresh_windows"
        XCTAssertTrue(L10n.text(windows, language: .simplifiedChinese).contains("通知区域"))
        XCTAssertTrue(L10n.text(windows, language: .simplifiedChinese).contains("配对设备…"))
        XCTAssertTrue(L10n.text(windows, language: .english).contains("notification area"))

        let linux = "ui.pairing_qr_expired_refresh_linux"
        for language in [AppLanguage.english, .simplifiedChinese] {
            XCTAssertTrue(L10n.text(linux, language: language).contains("agentd pair"))
        }

        let generic = "ui.pairing_qr_expired_refresh_generic"
        for language in [AppLanguage.english, .simplifiedChinese] {
            let value = L10n.text(generic, language: language)
            XCTAssertTrue(value.contains("Mac"), value)
            XCTAssertTrue(value.contains("Windows"), value)
            XCTAssertTrue(value.contains("agentd pair"), value)
        }
    }
}
