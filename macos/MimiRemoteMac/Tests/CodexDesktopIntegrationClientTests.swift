import Foundation
import XCTest
@testable import MimiRemoteMac

@MainActor
final class CodexDesktopIntegrationClientTests: XCTestCase {
    func testEnableClaimsOwnershipAndDisableRestoresPreviousValue() async throws {
        let defaults = makeDefaults()
        var daemon: String? = "previous"
        var codexHome: String?
        var setValues: [(String, String)] = []
        var unsetCount = 0
        let client = makeClient(
            defaults: defaults,
            environment: { key in key == CodexDesktopIntegrationClient.environmentKey ? daemon : codexHome },
            setEnvironment: { key, value in
                setValues.append((key, value))
                if key == CodexDesktopIntegrationClient.environmentKey { daemon = value }
                else { codexHome = value }
            },
            unsetEnvironment: { key in
                unsetCount += 1
                if key == CodexDesktopIntegrationClient.environmentKey { daemon = nil }
                else { codexHome = nil }
            }
        )

        do {
            _ = try await client.setEnabled(true, "/tmp/codex")
            XCTFail("非 1 的既有值必须 fail closed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("外部"))
        }
        XCTAssertEqual(daemon, "previous")
        XCTAssertTrue(setValues.isEmpty)

        // 非空且不是 1 的既有值不能偷偷覆盖；用户先清掉外部值后，Mimi
        // 才能声明两个环境键的 ownership，并在禁用时恢复 nil。
        daemon = nil
        let owned = try await client.setEnabled(true, "/tmp/codex")
        XCTAssertEqual(daemon, "1")
        XCTAssertEqual(codexHome, "/tmp/codex")
        XCTAssertTrue(owned.ownsEnvironment)
        XCTAssertTrue(owned.ownsCodexHome)
        XCTAssertNil(owned.previousValue)
        XCTAssertNil(owned.previousCodexHome)

        let restored = try await client.setEnabled(false, nil)
        XCTAssertNil(daemon)
        XCTAssertNil(codexHome)
        XCTAssertFalse(restored.ownsEnvironment)
        XCTAssertFalse(restored.ownsCodexHome)
        XCTAssertEqual(unsetCount, 2) // 测试计数器只记录两个官方键
    }

    func testExternalChangeIsNeverOverwrittenDuringRestore() async throws {
        let defaults = makeDefaults()
        var daemon: String?
        var codexHome: String?
        var writes = 0
        let client = makeClient(
            defaults: defaults,
            environment: { key in key == CodexDesktopIntegrationClient.environmentKey ? daemon : codexHome },
            setEnvironment: { key, value in
                writes += 1
                if key == CodexDesktopIntegrationClient.environmentKey { daemon = value }
                else { codexHome = value }
            },
            unsetEnvironment: { key in
                writes += 1
                if key == CodexDesktopIntegrationClient.environmentKey { daemon = nil }
                else { codexHome = nil }
            }
        )

        _ = try await client.setEnabled(true, "/tmp/codex")
        XCTAssertEqual(daemon, "1")
        daemon = "external"

        do {
            _ = try await client.setEnabled(false, nil)
            XCTFail("外部修改后不应部分恢复另一个键")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("外部"))
        }
        XCTAssertEqual(daemon, "external")
        XCTAssertEqual(codexHome, "/tmp/codex")
        XCTAssertEqual(writes, 2) // 测试计数器只记录两个官方键；预检失败后不再写入
    }

    func testEnableRollsBackFirstEnvironmentWhenSecondWriteFails() async throws {
        let defaults = makeDefaults()
        var daemon: String?
        var codexHome: String?
        var events: [String] = []
        let client = makeClient(
            defaults: defaults,
            environment: { key in
                key == CodexDesktopIntegrationClient.environmentKey ? daemon : codexHome
            },
            setEnvironment: { key, value in
                events.append("set-\(key)")
                if key == CodexDesktopIntegrationClient.codexHomeKey {
                    throw NSError(domain: "CodexDesktopTests", code: 1)
                }
                daemon = value
            },
            unsetEnvironment: { key in
                events.append("unset-\(key)")
                if key == CodexDesktopIntegrationClient.environmentKey { daemon = nil }
                else { codexHome = nil }
            }
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await client.setEnabled(true, "/tmp/codex")
        }

        let snapshot = try await client.inspect()
        XCTAssertFalse(snapshot.enabled)
        XCTAssertNil(daemon)
        XCTAssertNil(codexHome)
        XCTAssertFalse(snapshot.ownsEnvironment)
        XCTAssertEqual(events, [
            "set-CODEX_APP_SERVER_USE_LOCAL_DAEMON",
            "set-CODEX_HOME",
            "unset-CODEX_APP_SERVER_USE_LOCAL_DAEMON",
        ])
    }

    func testOwnershipEpochSetFailureRollsBackBothOfficialValues() async throws {
        let defaults = makeDefaults()
        let state = FakeLaunchctlState()
        state.failEpochSet = true
        let client = makeStateClient(defaults: defaults, state: state)

        await XCTAssertThrowsErrorAsync {
            _ = try await client.setEnabled(true, "/tmp/codex")
        }

        XCTAssertNil(state.daemon)
        XCTAssertNil(state.codexHome)
        XCTAssertNil(state.sessionEpoch)
        XCTAssertEqual(state.events, [
            "set-\(CodexDesktopIntegrationClient.environmentKey)",
            "set-\(CodexDesktopIntegrationClient.codexHomeKey)",
            "set-\(CodexDesktopIntegrationClient.ownershipEpochKey)",
            "unset-\(CodexDesktopIntegrationClient.codexHomeKey)",
            "unset-\(CodexDesktopIntegrationClient.environmentKey)",
        ])

        let snapshot = try await client.inspect()
        XCTAssertFalse(snapshot.ownsEnvironment)
        XCTAssertFalse(snapshot.ownsCodexHome)
        XCTAssertFalse(snapshot.ownsSessionEpoch)
    }

    func testDisableRollsBackFirstRestoreWhenSecondRestoreFails() async throws {
        let defaults = makeDefaults()
        var daemon: String?
        var codexHome: String?
        var failCodexHomeRestore = false
        let client = makeClient(
            defaults: defaults,
            environment: { key in
                key == CodexDesktopIntegrationClient.environmentKey ? daemon : codexHome
            },
            setEnvironment: { key, value in
                if key == CodexDesktopIntegrationClient.environmentKey { daemon = value }
                else { codexHome = value }
            },
            unsetEnvironment: { key in
                if key == CodexDesktopIntegrationClient.codexHomeKey, failCodexHomeRestore {
                    throw NSError(domain: "CodexDesktopTests", code: 2)
                }
                if key == CodexDesktopIntegrationClient.environmentKey { daemon = nil }
                else { codexHome = nil }
            }
        )

        _ = try await client.setEnabled(true, "/tmp/codex")
        failCodexHomeRestore = true
        await XCTAssertThrowsErrorAsync {
            _ = try await client.setEnabled(false, nil)
        }

        let snapshot = try await client.inspect()
        XCTAssertTrue(snapshot.enabled)
        XCTAssertEqual(daemon, "1")
        XCTAssertEqual(codexHome, "/tmp/codex")
        XCTAssertTrue(snapshot.ownsEnvironment)
        XCTAssertTrue(snapshot.ownsCodexHome)
    }

    func testOwnershipEpochUnsetFailureRollsBackOfficialRestoresAndKeepsLedger() async throws {
        let defaults = makeDefaults()
        let state = FakeLaunchctlState()
        let client = makeStateClient(defaults: defaults, state: state)
        _ = try await client.setEnabled(true, "/tmp/codex")
        state.events.removeAll()
        state.failEpochUnset = true

        await XCTAssertThrowsErrorAsync {
            _ = try await client.setEnabled(false, nil)
        }

        XCTAssertEqual(state.daemon, "1")
        XCTAssertEqual(state.codexHome, "/tmp/codex")
        XCTAssertNotNil(state.sessionEpoch)
        XCTAssertEqual(state.events, [
            "unset-\(CodexDesktopIntegrationClient.environmentKey)",
            "unset-\(CodexDesktopIntegrationClient.codexHomeKey)",
            "unset-\(CodexDesktopIntegrationClient.ownershipEpochKey)",
            "set-\(CodexDesktopIntegrationClient.codexHomeKey)",
            "set-\(CodexDesktopIntegrationClient.environmentKey)",
        ])

        let snapshot = try await client.inspect()
        XCTAssertTrue(snapshot.ownsEnvironment)
        XCTAssertTrue(snapshot.ownsCodexHome)
        XCTAssertTrue(snapshot.ownsSessionEpoch)
    }

    func testRestartTerminatesBeforeOpeningWithPerProcessEnvironment() async throws {
        let defaults = makeDefaults()
        var daemon: String?
        var codexHome: String?
        var appRunning = true
        var events: [String] = []
        let bundleURL = URL(filePath: "/Applications/Codex.app")
        let client = makeClient(
            defaults: defaults,
            environment: { key in key == CodexDesktopIntegrationClient.environmentKey ? daemon : codexHome },
            setEnvironment: { key, value in
                if key == CodexDesktopIntegrationClient.environmentKey { daemon = value }
                else { codexHome = value }
            },
            unsetEnvironment: { key in
                if key == CodexDesktopIntegrationClient.environmentKey { daemon = nil }
                else { codexHome = nil }
            },
            application: CodexDesktopApplicationClient(
                current: {
                    CodexDesktopApplicationInfo(bundleURL: bundleURL, isRunning: appRunning)
                },
                terminateAndWait: { url in
                    XCTAssertEqual(url, bundleURL)
                    events.append("terminate")
                    appRunning = false
                },
                open: { url, env in
                    XCTAssertEqual(url, bundleURL)
                    XCTAssertEqual(env[CodexDesktopIntegrationClient.environmentKey], "1")
                    XCTAssertEqual(env[CodexDesktopIntegrationClient.codexHomeKey], "/tmp/codex")
                    XCTAssertEqual(events, ["terminate"])
                    events.append("open")
                    appRunning = true
                }
            )
        )

        _ = try await client.setEnabled(true, "/tmp/codex")
        _ = try await client.restartAndApply()
        XCTAssertEqual(events, ["terminate", "open"])
    }

    func testLiveRestartRunsMigrationStrictlyBetweenTerminateAndOpen() async throws {
        let defaults = makeDefaults()
        let launchctl = FakeLaunchctlState()
        var appRunning = true
        var events: [String] = []
        let bundleURL = URL(filePath: "/Applications/Codex.app")
        let client = makeStateClient(
            defaults: defaults,
            state: launchctl,
            application: CodexDesktopApplicationClient(
                current: {
                    CodexDesktopApplicationInfo(bundleURL: bundleURL, isRunning: appRunning)
                },
                terminateAndWait: { _ in
                    events.append("terminate")
                    appRunning = false
                },
                open: { _, _ in
                    XCTAssertFalse(appRunning, "旧 Desktop 未完全退出前不能打开新实例")
                    events.append("open")
                    appRunning = true
                }
            )
        )

        _ = try await client.setEnabled(true, "/tmp/codex")
        _ = try await client.restartAndApply(afterTermination: {
            XCTAssertFalse(appRunning)
            events.append("migrate")
        })

        XCTAssertEqual(events, ["terminate", "migrate", "open"])
        XCTAssertTrue(appRunning)
    }

    func testLiveRestartMigrationFailureKeepsDesktopClosedAndNeverOpens() async throws {
        let defaults = makeDefaults()
        let launchctl = FakeLaunchctlState()
        var appRunning = true
        var events: [String] = []
        let bundleURL = URL(filePath: "/Applications/Codex.app")
        let client = makeStateClient(
            defaults: defaults,
            state: launchctl,
            application: CodexDesktopApplicationClient(
                current: {
                    CodexDesktopApplicationInfo(bundleURL: bundleURL, isRunning: appRunning)
                },
                terminateAndWait: { _ in
                    events.append("terminate")
                    appRunning = false
                },
                open: { _, _ in
                    events.append("open")
                    appRunning = true
                }
            )
        )

        _ = try await client.setEnabled(true, "/tmp/codex")
        do {
            _ = try await client.restartAndApply(afterTermination: {
                events.append("migrate")
                throw NSError(domain: "CodexDesktopTests", code: 157)
            })
            XCTFail("迁移失败必须向上抛出")
        } catch {
            XCTAssertEqual((error as NSError).code, 157)
        }

        XCTAssertEqual(events, ["terminate", "migrate"])
        XCTAssertFalse(appRunning)
    }

    func testLiveRestartDoesNotOpenDesktopThatWasAlreadyStoppedAtExecutionTime() async throws {
        let defaults = makeDefaults()
        let launchctl = FakeLaunchctlState()
        var events: [String] = []
        let bundleURL = URL(filePath: "/Applications/Codex.app")
        let client = makeStateClient(
            defaults: defaults,
            state: launchctl,
            application: CodexDesktopApplicationClient(
                current: {
                    CodexDesktopApplicationInfo(bundleURL: bundleURL, isRunning: false)
                },
                terminateAndWait: { _ in events.append("terminate") },
                open: { _, _ in events.append("open") }
            )
        )

        _ = try await client.setEnabled(true, "/tmp/codex")
        let snapshot = try await client.restartAndApply(afterTermination: {
            events.append("migrate")
        })

        XCTAssertEqual(events, ["migrate"])
        XCTAssertFalse(snapshot.appRunning)
    }

    func testExplicitEnableReacquiresOwnershipAfterLoginSessionReset() async throws {
        let defaults = makeDefaults()
        let launchctl = FakeLaunchctlState()
        let firstClient = makeStateClient(defaults: defaults, state: launchctl)

        let first = try await firstClient.setEnabled(true, "/tmp/codex")
        let firstEpoch = try XCTUnwrap(launchctl.sessionEpoch)
        XCTAssertTrue(first.ownsSessionEpoch)

        // 模拟注销/登录：launchd GUI 环境被清空，但 UserDefaults 属于同一用户
        // 仍保留旧会话 ownership 记录。新的 live client 代表下一次进程启动。
        launchctl.daemon = nil
        launchctl.codexHome = nil
        launchctl.sessionEpoch = nil

        let secondClient = makeStateClient(defaults: defaults, state: launchctl)
        let recovered = try await secondClient.setEnabled(true, "/tmp/codex")
        let secondEpoch = try XCTUnwrap(launchctl.sessionEpoch)
        XCTAssertNotEqual(firstEpoch, secondEpoch)
        XCTAssertEqual(launchctl.daemon, "1")
        XCTAssertEqual(launchctl.codexHome, "/tmp/codex")
        XCTAssertTrue(recovered.ownsEnvironment)
        XCTAssertTrue(recovered.ownsCodexHome)
        XCTAssertTrue(recovered.ownsSessionEpoch)
    }

    func testLegacyDaemonOnlyLedgerMigratesWithoutRewritingDaemonFlag() async throws {
        let defaults = makeDefaults()
        seedLegacyDaemonOnlyLedger(in: defaults)
        let launchctl = FakeLaunchctlState()
        launchctl.daemon = "1"
        let client = makeStateClient(defaults: defaults, state: launchctl)

        let migrated = try await client.setEnabled(true, "/tmp/codex")

        // 旧版已经证明 daemon flag 由 Mimi 写入；迁移只补齐 CODEX_HOME 和
        // 新会话 epoch，绝不能重复 setenv daemon 或覆盖外部值。
        XCTAssertEqual(launchctl.daemon, "1")
        XCTAssertEqual(launchctl.codexHome, "/tmp/codex")
        XCTAssertNotNil(launchctl.sessionEpoch)
        XCTAssertEqual(launchctl.events, [
            "set-\(CodexDesktopIntegrationClient.codexHomeKey)",
            "set-\(CodexDesktopIntegrationClient.ownershipEpochKey)",
        ])
        XCTAssertTrue(migrated.ownsEnvironment)
        XCTAssertTrue(migrated.ownsCodexHome)
        XCTAssertTrue(migrated.ownsSessionEpoch)
        XCTAssertEqual(defaults.string(forKey: "MimiRemoteMac.codexDesktop.writtenValue"), "1")
        XCTAssertTrue(defaults.bool(forKey: "MimiRemoteMac.codexDesktop.ownsEnvironment"))
        XCTAssertEqual(
            defaults.string(forKey: "MimiRemoteMac.codexDesktop.writtenCodexHome"),
            "/tmp/codex"
        )
        XCTAssertTrue(defaults.bool(forKey: "MimiRemoteMac.codexDesktop.ownsCodexHome"))
        XCTAssertEqual(
            defaults.string(forKey: "MimiRemoteMac.codexDesktop.writtenSessionEpoch"),
            launchctl.sessionEpoch
        )
        XCTAssertTrue(defaults.bool(forKey: "MimiRemoteMac.codexDesktop.ownsSessionEpoch"))
        XCTAssertEqual(
            defaults.string(forKey: "MimiRemoteMac.codexDesktop.codexHome"),
            "/tmp/codex"
        )
    }

    func testLegacyLedgerWithExplicitFalseNewOwnershipKeyRefusesMigration() async throws {
        let defaults = makeDefaults()
        seedLegacyDaemonOnlyLedger(in: defaults)
        defaults.set(false, forKey: "MimiRemoteMac.codexDesktop.ownsCodexHome")
        let launchctl = FakeLaunchctlState()
        launchctl.daemon = "1"
        let client = makeStateClient(defaults: defaults, state: launchctl)

        await XCTAssertThrowsErrorAsync {
            _ = try await client.setEnabled(true, "/tmp/codex")
        }

        XCTAssertEqual(launchctl.daemon, "1")
        XCTAssertNil(launchctl.codexHome)
        XCTAssertNil(launchctl.sessionEpoch)
        XCTAssertTrue(launchctl.events.isEmpty)
    }

    func testLegacyLedgerWithPreviousValueRefusesMigration() async throws {
        let defaults = makeDefaults()
        seedLegacyDaemonOnlyLedger(in: defaults)
        defaults.set("previous", forKey: "MimiRemoteMac.codexDesktop.previousValue")
        let launchctl = FakeLaunchctlState()
        launchctl.daemon = "1"
        let client = makeStateClient(defaults: defaults, state: launchctl)

        await XCTAssertThrowsErrorAsync {
            _ = try await client.setEnabled(true, "/tmp/codex")
        }

        XCTAssertEqual(launchctl.daemon, "1")
        XCTAssertNil(launchctl.codexHome)
        XCTAssertNil(launchctl.sessionEpoch)
        XCTAssertTrue(launchctl.events.isEmpty)
    }

    func testSameDaemonAndHomeValuesWithoutLegacyLedgerAreNotClaimed() async throws {
        let defaults = makeDefaults()
        let launchctl = FakeLaunchctlState()
        launchctl.daemon = "1"
        launchctl.codexHome = "/tmp/codex"
        let client = makeStateClient(defaults: defaults, state: launchctl)

        await XCTAssertThrowsErrorAsync {
            _ = try await client.setEnabled(true, "/tmp/codex")
        }

        XCTAssertEqual(launchctl.daemon, "1")
        XCTAssertEqual(launchctl.codexHome, "/tmp/codex")
        XCTAssertNil(launchctl.sessionEpoch)
        XCTAssertTrue(launchctl.events.isEmpty)
        XCTAssertFalse(defaults.bool(forKey: "MimiRemoteMac.codexDesktop.ownsEnvironment"))
        XCTAssertFalse(defaults.bool(forKey: "MimiRemoteMac.codexDesktop.ownsCodexHome"))
        XCTAssertFalse(defaults.bool(forKey: "MimiRemoteMac.codexDesktop.ownsSessionEpoch"))
    }

    func testLegacyDaemonOnlyLedgerRejectsExternalCodexHome() async throws {
        let defaults = makeDefaults()
        seedLegacyDaemonOnlyLedger(in: defaults)
        let launchctl = FakeLaunchctlState()
        launchctl.daemon = "1"
        launchctl.codexHome = "/other/codex"
        let client = makeStateClient(defaults: defaults, state: launchctl)

        await XCTAssertThrowsErrorAsync {
            _ = try await client.setEnabled(true, "/tmp/codex")
        }

        XCTAssertEqual(launchctl.daemon, "1")
        XCTAssertEqual(launchctl.codexHome, "/other/codex")
        XCTAssertNil(launchctl.sessionEpoch)
        XCTAssertTrue(launchctl.events.isEmpty)
    }

    func testLegacyDaemonOnlyLedgerRejectsExternalSessionEpoch() async throws {
        let defaults = makeDefaults()
        seedLegacyDaemonOnlyLedger(in: defaults)
        let launchctl = FakeLaunchctlState()
        launchctl.daemon = "1"
        launchctl.sessionEpoch = "external-epoch"
        let client = makeStateClient(defaults: defaults, state: launchctl)

        await XCTAssertThrowsErrorAsync {
            _ = try await client.setEnabled(true, "/tmp/codex")
        }

        XCTAssertEqual(launchctl.daemon, "1")
        XCTAssertNil(launchctl.codexHome)
        XCTAssertEqual(launchctl.sessionEpoch, "external-epoch")
        XCTAssertTrue(launchctl.events.isEmpty)
    }

    func testCommittedWriteDoesNotDependOnPostCommitGetenv() async throws {
        let defaults = makeDefaults()
        let state = FakeLaunchctlState()
        let client = CodexDesktopIntegrationClient.live(
            defaults: defaults,
            launchctl: CodexDesktopLaunchctlClient(
                getenv: { key in
                    if state.failReads {
                        throw NSError(
                            domain: "CodexDesktopTests",
                            code: 99,
                            userInfo: [NSLocalizedDescriptionKey: "模拟提交后的 launchctl 读取失败"]
                        )
                    }
                    switch key {
                    case CodexDesktopIntegrationClient.environmentKey:
                        return state.daemon
                    case CodexDesktopIntegrationClient.codexHomeKey:
                        return state.codexHome
                    case CodexDesktopIntegrationClient.ownershipEpochKey:
                        return state.sessionEpoch
                    default:
                        return nil
                    }
                },
                setenv: { key, value in
                    switch key {
                    case CodexDesktopIntegrationClient.environmentKey:
                        state.daemon = value
                    case CodexDesktopIntegrationClient.codexHomeKey:
                        state.codexHome = value
                    case CodexDesktopIntegrationClient.ownershipEpochKey:
                        state.sessionEpoch = value
                        // 后续任何 getenv 都模拟瞬时失败；setEnabled 仍应返回
                        // 已提交快照，而不是让 HostStore 回滚 backend。
                        state.failReads = true
                    default:
                        break
                    }
                },
                unsetenv: { key in
                    switch key {
                    case CodexDesktopIntegrationClient.environmentKey:
                        state.daemon = nil
                    case CodexDesktopIntegrationClient.codexHomeKey:
                        state.codexHome = nil
                    case CodexDesktopIntegrationClient.ownershipEpochKey:
                        state.sessionEpoch = nil
                    default:
                        break
                    }
                }
            ),
            application: CodexDesktopApplicationClient(
                current: { CodexDesktopApplicationInfo(bundleURL: nil, isRunning: false) },
                terminateAndWait: { _ in },
                open: { _, _ in }
            )
        )

        let snapshot = try await client.setEnabled(true, "/tmp/codex")
        XCTAssertEqual(state.daemon, "1")
        XCTAssertEqual(state.codexHome, "/tmp/codex")
        XCTAssertNotNil(state.sessionEpoch)
        XCTAssertTrue(snapshot.ownsEnvironment)
        XCTAssertTrue(snapshot.ownsCodexHome)
        XCTAssertTrue(snapshot.ownsSessionEpoch)
    }

    func testNewSessionExternalSameValuesAreNotClaimedOrRemoved() async throws {
        let defaults = makeDefaults()
        let launchctl = FakeLaunchctlState()
        let firstClient = makeStateClient(defaults: defaults, state: launchctl)
        _ = try await firstClient.setEnabled(true, "/tmp/codex")

        // 新登录会话里另一个程序先写入完全相同的两个官方值，但没有 Mimi
        // ownership epoch。显式启用必须 fail closed，不能认领或在禁用时删除。
        launchctl.daemon = nil
        launchctl.codexHome = nil
        launchctl.sessionEpoch = nil
        launchctl.daemon = "1"
        launchctl.codexHome = "/tmp/codex"

        let secondClient = makeStateClient(defaults: defaults, state: launchctl)
        await XCTAssertThrowsErrorAsync {
            _ = try await secondClient.setEnabled(true, "/tmp/codex")
        }
        XCTAssertEqual(launchctl.daemon, "1")
        XCTAssertEqual(launchctl.codexHome, "/tmp/codex")
        XCTAssertNil(launchctl.sessionEpoch)

        // 禁用同样不能因为旧 UserDefaults ownership 就删除新会话外部值。
        await XCTAssertThrowsErrorAsync {
            _ = try await secondClient.setEnabled(false, nil)
        }
        XCTAssertEqual(launchctl.daemon, "1")
        XCTAssertEqual(launchctl.codexHome, "/tmp/codex")
    }

    func testClearedOfficialValuesWithOldMarkerFailClosed() async throws {
        let defaults = makeDefaults()
        let launchctl = FakeLaunchctlState()
        let firstClient = makeStateClient(defaults: defaults, state: launchctl)
        _ = try await firstClient.setEnabled(true, "/tmp/codex")
        let oldEpoch = try XCTUnwrap(launchctl.sessionEpoch)

        // 同一 bootstrap 会话里两个官方值被外部清空，但 Mimi marker 仍存在；
        // 不能把这次部分清空当作注销/登录来重写。
        launchctl.daemon = nil
        launchctl.codexHome = nil

        let secondClient = makeStateClient(defaults: defaults, state: launchctl)
        await XCTAssertThrowsErrorAsync {
            _ = try await secondClient.setEnabled(true, "/tmp/codex")
        }
        XCTAssertNil(launchctl.daemon)
        XCTAssertNil(launchctl.codexHome)
        XCTAssertEqual(launchctl.sessionEpoch, oldEpoch)
    }

    func testDisableAfterLoginSessionResetOnlyClearsStaleOwnership() async throws {
        let defaults = makeDefaults()
        let launchctl = FakeLaunchctlState()
        let firstClient = makeStateClient(defaults: defaults, state: launchctl)
        _ = try await firstClient.setEnabled(true, "/tmp/codex")
        launchctl.daemon = nil
        launchctl.codexHome = nil
        launchctl.sessionEpoch = nil

        let secondClient = makeStateClient(defaults: defaults, state: launchctl)
        let disabled = try await secondClient.setEnabled(false, nil)
        XCTAssertFalse(disabled.enabled)
        XCTAssertFalse(disabled.ownsEnvironment)
        XCTAssertFalse(disabled.ownsCodexHome)
        XCTAssertFalse(disabled.ownsSessionEpoch)
        XCTAssertNil(launchctl.daemon)
        XCTAssertNil(launchctl.codexHome)
        XCTAssertNil(launchctl.sessionEpoch)
    }

    func testRestartWaitsForAllMatchingInstancesBeforeOpening() async throws {
        let defaults = makeDefaults()
        let launchctl = FakeLaunchctlState()
        var matchingInstances = 2
        var events: [String] = []
        let bundleURL = URL(filePath: "/Applications/Codex.app")
        let client = makeStateClient(
            defaults: defaults,
            state: launchctl,
            application: CodexDesktopApplicationClient(
                current: {
                    CodexDesktopApplicationInfo(
                        bundleURL: bundleURL,
                        isRunning: matchingInstances > 0
                    )
                },
                terminateAndWait: { url in
                    XCTAssertEqual(url, bundleURL)
                    events.append("terminate-all-\(matchingInstances)")
                    // 这个 seam 的一次调用代表 live client 对 bundle id 的所有
                    // NSRunningApplication 实例发送普通 terminate 并等待全部结束。
                    matchingInstances = 0
                },
                open: { url, environment in
                    XCTAssertEqual(url, bundleURL)
                    XCTAssertEqual(matchingInstances, 0)
                    XCTAssertEqual(environment[CodexDesktopIntegrationClient.environmentKey], "1")
                    events.append("open")
                }
            )
        )

        _ = try await client.setEnabled(true, "/tmp/codex")
        _ = try await client.restartAndApply()
        XCTAssertEqual(events, ["terminate-all-2", "open"])
    }

    private func makeClient(
        defaults: UserDefaults,
        environment: @escaping @MainActor (String) async throws -> String?,
        setEnvironment: @escaping @MainActor (String, String) async throws -> Void,
        unsetEnvironment: @escaping @MainActor (String) async throws -> Void,
        application: CodexDesktopApplicationClient? = nil
    ) -> CodexDesktopIntegrationClient {
        var sessionEpoch: String?
        return CodexDesktopIntegrationClient.live(
            defaults: defaults,
            launchctl: CodexDesktopLaunchctlClient(
                getenv: { key in
                    if key == CodexDesktopIntegrationClient.ownershipEpochKey {
                        return sessionEpoch
                    }
                    return try await environment(key)
                },
                setenv: { key, value in
                    if key == CodexDesktopIntegrationClient.ownershipEpochKey {
                        sessionEpoch = value
                    } else {
                        try await setEnvironment(key, value)
                    }
                },
                unsetenv: { key in
                    if key == CodexDesktopIntegrationClient.ownershipEpochKey {
                        sessionEpoch = nil
                    } else {
                        try await unsetEnvironment(key)
                    }
                }
            ),
            application: application ?? CodexDesktopApplicationClient(
                current: { CodexDesktopApplicationInfo(bundleURL: nil, isRunning: false) },
                terminateAndWait: { _ in },
                open: { _, _ in }
            )
        )
    }

    private func makeStateClient(
        defaults: UserDefaults,
        state: FakeLaunchctlState,
        application: CodexDesktopApplicationClient? = nil
    ) -> CodexDesktopIntegrationClient {
        return CodexDesktopIntegrationClient.live(
            defaults: defaults,
            launchctl: CodexDesktopLaunchctlClient(
                getenv: { key in
                    switch key {
                    case CodexDesktopIntegrationClient.environmentKey:
                        return state.daemon
                    case CodexDesktopIntegrationClient.codexHomeKey:
                        return state.codexHome
                    case CodexDesktopIntegrationClient.ownershipEpochKey:
                        return state.sessionEpoch
                    default:
                        return nil
                    }
                },
                setenv: { key, value in
                    switch key {
                    case CodexDesktopIntegrationClient.environmentKey:
                        state.events.append("set-\(key)")
                        state.daemon = value
                    case CodexDesktopIntegrationClient.codexHomeKey:
                        state.events.append("set-\(key)")
                        state.codexHome = value
                    case CodexDesktopIntegrationClient.ownershipEpochKey:
                        state.events.append("set-\(key)")
                        if state.failEpochSet {
                            throw NSError(
                                domain: "CodexDesktopTests",
                                code: 3,
                                userInfo: [NSLocalizedDescriptionKey: "模拟 ownership epoch 写入失败"]
                            )
                        }
                        state.sessionEpoch = value
                    default:
                        break
                    }
                },
                unsetenv: { key in
                    switch key {
                    case CodexDesktopIntegrationClient.environmentKey:
                        state.events.append("unset-\(key)")
                        state.daemon = nil
                    case CodexDesktopIntegrationClient.codexHomeKey:
                        state.events.append("unset-\(key)")
                        state.codexHome = nil
                    case CodexDesktopIntegrationClient.ownershipEpochKey:
                        state.events.append("unset-\(key)")
                        if state.failEpochUnset {
                            throw NSError(
                                domain: "CodexDesktopTests",
                                code: 4,
                                userInfo: [NSLocalizedDescriptionKey: "模拟 ownership epoch 清理失败"]
                            )
                        }
                        state.sessionEpoch = nil
                    default:
                        break
                    }
                }
            ),
            application: application ?? CodexDesktopApplicationClient(
                current: { CodexDesktopApplicationInfo(bundleURL: nil, isRunning: false) },
                terminateAndWait: { _ in },
                open: { _, _ in }
            )
        )
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "MimiRemoteMac.CodexDesktopTests.\(UUID().uuidString)")!
    }

    private func seedLegacyDaemonOnlyLedger(in defaults: UserDefaults) {
        defaults.set(true, forKey: "MimiRemoteMac.codexDesktop.enabled")
        defaults.set("1", forKey: "MimiRemoteMac.codexDesktop.writtenValue")
        defaults.set(true, forKey: "MimiRemoteMac.codexDesktop.ownsEnvironment")
    }

    private func XCTAssertThrowsErrorAsync(
        _ expression: @escaping @MainActor () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await expression()
            XCTFail("Expected expression to throw", file: file, line: line)
        } catch {}
    }
}

private final class FakeLaunchctlState {
    var daemon: String?
    var codexHome: String?
    var sessionEpoch: String?
    var failReads = false
    var failEpochSet = false
    var failEpochUnset = false
    var events: [String] = []
}
