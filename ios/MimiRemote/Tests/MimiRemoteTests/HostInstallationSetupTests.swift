import Foundation
import XCTest
@testable import MimiRemote

final class HostInstallationSetupTests: XCTestCase {
    private func withInterfaceLanguage(_ language: AppLanguage, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: AppLanguage.preferenceKey)
        defaults.set(language.rawValue, forKey: AppLanguage.preferenceKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: AppLanguage.preferenceKey)
            } else {
                defaults.removeObject(forKey: AppLanguage.preferenceKey)
            }
        }
        body()
    }

    func testWindowsInstallationGuidanceContainsZeroBrewFromCollapsedToExpanded() {
        for language in [AppLanguage.simplifiedChinese, .english] {
            withInterfaceLanguage(language) {
                let texts = HostInstallationPlatform.windows.allVisibleGuidanceTexts
                XCTAssertFalse(texts.isEmpty)
                for text in texts {
                    XCTAssertFalse(
                        text.localizedCaseInsensitiveContains("brew"),
                        "Windows installation guidance [\(language.rawValue)] must not mention brew: \(text)"
                    )
                }

                let guide = HostInstallationPlatform.windows.commandLineGuide
                XCTAssertEqual(
                    guide.steps.map(\.command),
                    [HostInstallationPlatform.windowsPowerShellStartCommand]
                )
                XCTAssertEqual(
                    HostInstallationPlatform.windowsPowerShellStartCommand,
                    #"& "$env:LOCALAPPDATA\Programs\Mimi Remote\agentd.exe" up"#
                )
                XCTAssertNotNil(guide.introNote)

                if language == .simplifiedChinese {
                    XCTAssertTrue(HostInstallationPlatform.windows.afterInstallNote.contains("任务栏"))
                    XCTAssertTrue(HostInstallationPlatform.windows.afterInstallNote.contains("配对设备…"))
                    XCTAssertTrue(guide.introNote?.contains("任务栏") == true)
                    XCTAssertTrue(guide.footerNote.contains("自定义目录"))
                } else {
                    XCTAssertTrue(HostInstallationPlatform.windows.afterInstallNote.localizedCaseInsensitiveContains("taskbar"))
                    XCTAssertTrue(HostInstallationPlatform.windows.afterInstallNote.contains("Pair Device…"))
                    XCTAssertTrue(guide.introNote?.localizedCaseInsensitiveContains("taskbar") == true)
                    XCTAssertTrue(guide.footerNote.localizedCaseInsensitiveContains("custom install folder"))
                }
            }
        }
    }

    func testMacInstallationGuidanceKeepsDMGAndHomebrewCommands() {
        for language in [AppLanguage.simplifiedChinese, .english] {
            withInterfaceLanguage(language) {
                let guide = HostInstallationPlatform.mac.commandLineGuide
                XCTAssertEqual(
                    guide.steps.map(\.command),
                    [
                        "brew install gaixianggeng/tap/mimi-remote",
                        "agentd up",
                    ]
                )
                XCTAssertTrue(guide.footerNote.contains("agentd pair"))
                XCTAssertEqual(HostInstallationPlatform.mac.installerURL, AppExternalLinks.macInstaller)
                XCTAssertEqual(HostInstallationPlatform.mac.releaseURL, AppExternalLinks.macRelease)
            }
        }
    }

    func testFirstConnectionAssistantGuideCoversAllFourAssistantsWithAllowlistedHTTPSURLs() {
        let items = FirstConnectionAssistantGuideItem.allItems
        XCTAssertEqual(items.map(\.id), ["codex", "claude", "agy", "deepseek"])
        XCTAssertEqual(
            items.map(\.fixURL),
            [.codex, .claude, .agy, .harness]
        )
        for item in items {
            XCTAssertEqual(item.destination.scheme, "https")
            XCTAssertFalse(item.destination.absoluteString.contains("App-Prefs:"))
        }

        for language in [AppLanguage.simplifiedChinese, .english] {
            withInterfaceLanguage(language) {
                let note = L10n.text("ui.first_connection_codex_note")
                let summary = L10n.text("ui.first_connection_assistant_guide_summary")
                for brand in ["Codex", "Claude Code", "Antigravity", "DeepSeek Harness"] {
                    XCTAssertTrue(note.contains(brand), "Step 1 note [\(language.rawValue)] must mention \(brand): \(note)")
                }
                for item in items {
                    XCTAssertNotEqual(item.title, item.titleKey)
                    XCTAssertFalse(item.title.isEmpty)
                }
                if language == .simplifiedChinese {
                    XCTAssertTrue(note.contains("任意一个"))
                    XCTAssertTrue(summary.contains("任意 1 个"))
                } else {
                    XCTAssertTrue(note.localizedCaseInsensitiveContains("any one"))
                    XCTAssertTrue(summary.localizedCaseInsensitiveContains("any 1"))
                }
            }
        }
    }

    func testNewSessionUnavailableHintOnlyClaimsSignedOutWithPositiveEvidence() {
        let allEnabled = Set(WorkspaceSessionRuntimeChoice.allCases)

        for language in [AppLanguage.simplifiedChinese, .english] {
            withInterfaceLanguage(language) {
                let generic = L10n.text("ui.runtime_unavailable_hint")
                // No diagnostics, unknown reason, probe failure, refresh_in_progress, or stale quota -> generic unavailable, NOT signed out.
                XCTAssertEqual(
                    NewSessionSheet.unavailableRuntimeMessage(
                        diagnosticsByProvider: [:],
                        enabledRuntimes: allEnabled
                    ),
                    generic
                )
                XCTAssertFalse(generic.contains("尚未登录"))
                XCTAssertFalse(generic.localizedCaseInsensitiveContains("not signed in"))
                XCTAssertFalse(generic.localizedCaseInsensitiveContains("sign in"))
                XCTAssertFalse(generic.contains("Codex"))

                for nonSignedOutStatus in ["unavailable", "runtime_probe_failed", "probe_failed", "refresh_in_progress", "quota_stale", ""] {
                    let diagnostic = RuntimeChannelDiagnostic(
                        provider: "claude",
                        status: nonSignedOutStatus,
                        cliVersion: nil,
                        minimumCLIVersion: nil,
                        lastProbeError: nil,
                        fix: nil
                    )
                    let message = NewSessionSheet.unavailableRuntimeMessage(
                        diagnosticsByProvider: ["claude": diagnostic],
                        enabledRuntimes: allEnabled
                    )
                    XCTAssertEqual(message, generic, "Status \(nonSignedOutStatus) must not claim signed out")
                }

                // Positive signed-out status -> explicitly names signed-out runtime.
                let signedOut = RuntimeChannelDiagnostic(
                    provider: "claude",
                    status: "claude_signed_out",
                    cliVersion: "2.1.0",
                    minimumCLIVersion: nil,
                    lastProbeError: nil,
                    fix: nil
                )
                let signedOutMessage = NewSessionSheet.unavailableRuntimeMessage(
                    diagnosticsByProvider: ["claude": signedOut],
                    enabledRuntimes: allEnabled
                )
                XCTAssertNotEqual(signedOutMessage, generic)
                XCTAssertTrue(signedOutMessage.contains("Claude Code"))
                if language == .simplifiedChinese {
                    XCTAssertTrue(signedOutMessage.contains("尚未登录"))
                } else {
                    XCTAssertTrue(signedOutMessage.localizedCaseInsensitiveContains("not signed in"))
                }

                XCTAssertEqual(NewSessionSheet.unavailableRuntimeMessage(
                    diagnosticsByProvider: ["claude": signedOut], enabledRuntimes: [.codex]
                ), generic)
                XCTAssertEqual(NewSessionSheet.unavailableRuntimeMessage(
                    diagnosticsByProvider: ["codex": signedOut], enabledRuntimes: [.codex]
                ), generic)

                // Version-unsupported diagnostic stays distinct from signed-out.
                let unsupported = RuntimeChannelDiagnostic(
                    provider: "agy",
                    status: "agy_unsupported",
                    cliVersion: "1.0.0",
                    minimumCLIVersion: "1.5.0",
                    lastProbeError: nil,
                    fix: nil
                )
                let unsupportedMessage = NewSessionSheet.unavailableRuntimeMessage(
                    diagnosticsByProvider: ["agy": unsupported],
                    enabledRuntimes: allEnabled
                )
                XCTAssertTrue(unsupportedMessage.contains("1.5.0"))
                XCTAssertFalse(unsupportedMessage.contains("尚未登录"))
                XCTAssertFalse(unsupportedMessage.localizedCaseInsensitiveContains("not signed in"))
            }
        }
    }

    @MainActor
    func testPairingTicketReadsExpiryDirectlyFromLinkWithoutFixedTenMinuteWindow() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date()
        let issued = formatter.string(from: now.addingTimeInterval(-120))
        func link(expiringIn seconds: TimeInterval) throws -> URL {
            var link = URLComponents(string: "mimiremote://pair")!
            link.queryItems = [
                URLQueryItem(name: "endpoint", value: "http://127.0.0.1:8787"),
                URLQueryItem(name: "issued_at", value: issued),
                URLQueryItem(name: "expires_at", value: formatter.string(from: now.addingTimeInterval(seconds))),
                URLQueryItem(name: "pair_sig", value: "test-signature")
            ]
            return try XCTUnwrap(link.url)
        }
        XCTAssertNotNil(try AppStore.pairingTicket(from: link(expiringIn: 60)))
        XCTAssertThrowsError(try AppStore.pairingTicket(from: link(expiringIn: -30))) {
            XCTAssertEqual($0 as? PairingLinkError, .expired)
        }
    }
}
