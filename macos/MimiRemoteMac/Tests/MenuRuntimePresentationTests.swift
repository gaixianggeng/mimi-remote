import XCTest
@testable import MimiRemoteMac

final class MenuRuntimePresentationTests: XCTestCase {
    func testConnectedNonAPIKeyRuntimeDoesNotUseAPIKeyDetail() {
        for authMode in ["chatgpt", "oauth"] {
            let runtime = makeRuntime(state: .connected, authMode: authMode)

            XCTAssertEqual(
                MenuRuntimePresentation.detailText(
                    for: runtime,
                    missingDetail: "缺失"
                ),
                "尚未获取到额度数据。",
                "\(authMode) 已连接状态不能显示为 API Key"
            )
        }
    }

    func testUnavailableCodexExplainsWhatToInstall() {
        func codex(state: AgentRuntimeConnectionState, enabled: Bool = true, reason: String? = nil) -> AgentRuntimeStatus {
            AgentRuntimeStatus(
                id: "codex",
                title: "Codex",
                enabled: enabled,
                state: state,
                version: nil,
                startedAt: nil,
                authMode: nil,
                planType: nil,
                reason: reason,
                rateLimits: nil
            )
        }

        let guidance = MenuRuntimePresentation.codexUnavailableGuidance(for: codex(state: .unavailable))
        XCTAssertTrue(guidance?.contains("安装并登录 Codex") == true)
        // 正在检查、用户主动关闭、可用和其它运行时都不提示安装。
        XCTAssertNil(MenuRuntimePresentation.codexUnavailableGuidance(for: codex(state: .unavailable, reason: "refresh_in_progress")))
        XCTAssertNil(MenuRuntimePresentation.codexUnavailableGuidance(for: codex(state: .unavailable, enabled: false)))
        XCTAssertNil(MenuRuntimePresentation.codexUnavailableGuidance(for: codex(state: .connected)))
        XCTAssertNil(MenuRuntimePresentation.codexUnavailableGuidance(for: makeRuntime(id: "claude", state: .unavailable, authMode: "oauth")))
        XCTAssertNil(MenuRuntimePresentation.codexUnavailableGuidance(for: nil))
    }

    func testConnectedAPIKeyRuntimeUsesAPIKeyDetail() {
        let runtime = makeRuntime(state: .connected, authMode: "api_key")

        XCTAssertEqual(
            MenuRuntimePresentation.detailText(
                for: runtime,
                missingDetail: "缺失"
            ),
            "API Key 已配置（按量计费），将在首次请求时验证有效性。"
        )
    }

    func testRuntimeVersionUsesProviderSpecificLabel() {
        let codex = makeRuntime(
            id: "codex",
            state: .connected,
            version: "0.146.0-alpha.3.1",
            authMode: "chatgpt"
        )
        let claude = makeRuntime(
            id: "claude",
            state: .connected,
            version: "0.2.6",
            authMode: "oauth"
        )

        XCTAssertEqual(
            MenuRuntimePresentation.versionText(for: codex),
            "Codex CLI 0.146.0-alpha.3.1"
        )
        XCTAssertEqual(
            MenuRuntimePresentation.versionText(for: claude),
            "Claude Bridge 0.2.6"
        )
        XCTAssertNil(
            MenuRuntimePresentation.versionText(
                for: makeRuntime(state: .available, authMode: "api_key")
            )
        )
    }

    func testRuntimeUptimeUsesResidentProcessStartTime() {
        let runtime = makeRuntime(
            id: "codex",
            state: .connected,
            startedAt: "2026-07-27T08:15:00Z",
            authMode: "chatgpt"
        )
        let now = ISO8601DateFormatter().date(from: "2026-07-29T12:45:00Z")!

        XCTAssertEqual(
            MenuRuntimePresentation.uptimeText(for: runtime, at: now),
            "已运行 2天 4小时"
        )
        XCTAssertNil(
            MenuRuntimePresentation.uptimeText(
                for: makeRuntime(state: .connected, authMode: "oauth"),
                at: now
            )
        )
    }

    func testUsageItemsMatchSettingsThreeRingSemantics() {
        let codex = makeRuntime(
            id: "codex",
            title: "Codex",
            state: .connected,
            authMode: "chatgpt",
            rateLimits: makeRateLimits(primaryUsed: 80, secondaryUsed: 42)
        )
        let claude = makeRuntime(
            id: "claude",
            title: "Claude",
            state: .connected,
            authMode: "oauth",
            rateLimits: makeRateLimits(primaryUsed: 99, secondaryUsed: 48)
        )

        let items = MenuRuntimePresentation.usageItems(codex: codex, claude: claude)

        XCTAssertEqual(
            items.map(\.id),
            ["codex:secondary", "claude:secondary", "claude:primary"]
        )
        XCTAssertEqual(
            items.map(\.tintRole),
            [.codexLong, .claudeLong, .claudeShort]
        )
        XCTAssertEqual(
            items.map(\.window.remainingPercentText),
            ["58%", "52%", "1%"]
        )
    }

    func testUsageSlotsKeepThreeAlignedRowsWhileClaudeQuotaIsUnavailable() {
        let codex = makeRuntime(
            id: "codex",
            title: "Codex",
            state: .connected,
            authMode: "chatgpt",
            rateLimits: makeRateLimits(primaryUsed: 80, secondaryUsed: 42)
        )
        let claude = makeRuntime(
            id: "claude",
            title: "Claude",
            state: .available,
            authMode: "oauth"
        )

        let slots = MenuRuntimePresentation.usageSlots(codex: codex, claude: claude)

        XCTAssertEqual(slots.map(\.id), ["codex:long", "claude:long", "claude:short"])
        XCTAssertNotNil(slots[0].item)
        XCTAssertNil(slots[1].item)
        XCTAssertNil(slots[2].item)
        XCTAssertEqual(slots[1].windowLabel, "长周期")
        XCTAssertEqual(slots[2].windowLabel, "短周期")
    }

    private func makeRuntime(
        id: String = "test",
        title: String = "Test",
        state: AgentRuntimeConnectionState,
        version: String? = nil,
        startedAt: String? = nil,
        authMode: String,
        rateLimits: AgentRuntimeRateLimits? = nil
    ) -> AgentRuntimeStatus {
        AgentRuntimeStatus(
            id: id,
            title: title,
            enabled: true,
            state: state,
            version: version,
            startedAt: startedAt,
            authMode: authMode,
            planType: nil,
            reason: nil,
            rateLimits: rateLimits
        )
    }

    private func makeRateLimits(
        primaryUsed: Double,
        secondaryUsed: Double
    ) -> AgentRuntimeRateLimits {
        AgentRuntimeRateLimits(
            limitID: nil,
            limitName: nil,
            planType: nil,
            reachedType: nil,
            availability: "available",
            unavailableReason: nil,
            primary: AgentRuntimeRateLimitWindow(
                usedPercent: primaryUsed,
                windowDurationMins: 300,
                resetsAt: nil
            ),
            secondary: AgentRuntimeRateLimitWindow(
                usedPercent: secondaryUsed,
                windowDurationMins: 10_080,
                resetsAt: nil
            ),
            hasCredits: nil,
            creditsUnlimited: nil,
            creditBalance: nil
        )
    }
}
