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
        XCTAssertEqual(L10n.text("ui.settings"), "settings")
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
        XCTAssertEqual(L10n.text("ui.settings", language: .english), "settings")
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
            ("ui.personalization", "Appearance & Personalization", "外观与个性化"),
            ("ui.advanced_and_development", "Advanced & Development", "高级与开发"),
            ("ui.about_and_legal", "About & Legal", "关于与法律")
        ]

        for (key, english, simplifiedChinese) in expectedValues {
            XCTAssertEqual(L10n.text(key, language: .english), english)
            XCTAssertEqual(L10n.text(key, language: .simplifiedChinese), simplifiedChinese)
        }
    }

    func testSessionRowStatefulActionLabelsAreLocalized() {
        let expectedValues: [(String, String, String)] = [
            ("ui.pin_to_top", "pin to top", "置顶"),
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
        XCTAssertEqual(SettingsLayoutMetrics.iconSlot, 28)
        XCTAssertEqual(SettingsLayoutMetrics.symbolPointSize, 18)
        XCTAssertEqual(
            SettingsLayoutMetrics.statusModuleCornerRadius,
            WorkbenchPageLayout.contentPanelCornerRadius
        )
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

    func testVoiceInputProviderDefaultsToCodexAndPreservesKnownSelection() {
        let suiteName = "VoiceInputProviderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(VoiceInputProvider.stored(in: defaults), .codex)
        defaults.set(VoiceInputProvider.apple.rawValue, forKey: VoiceInputProvider.storageKey)
        XCTAssertEqual(VoiceInputProvider.stored(in: defaults), .apple)
        defaults.set(VoiceInputProvider.codex.rawValue, forKey: VoiceInputProvider.storageKey)
        XCTAssertEqual(VoiceInputProvider.stored(in: defaults), .codex)
        defaults.set("future-provider", forKey: VoiceInputProvider.storageKey)
        XCTAssertEqual(VoiceInputProvider.stored(in: defaults), .codex)
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
}
