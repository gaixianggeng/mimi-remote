import SnapshotTesting
import SwiftUI
import XCTest
@testable import MimiRemote

/// 共享表单的内容基线覆盖首次配置、已保存电脑和辅助功能字号。
@MainActor
final class ConnectionSettingsSnapshotTests: SimplifiedChineseSnapshotTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try SnapshotTestEnvironment.requireFixedSimulator()
    }

    func testUnconfiguredConnectionSettingsOnCompactWidth() {
        assertConnectionSettings(
            profiles: [],
            width: 393,
            height: 852,
            named: "unconfigured-compact"
        )
    }

    func testUnconfiguredConnectionSettingsOnWideWidth() {
        assertConnectionSettings(
            profiles: [],
            width: 720,
            height: 1_000,
            named: "unconfigured-wide"
        )
    }

    func testUnconfiguredConnectionSettingsOnCompactWidthAtAccessibilitySize() {
        assertConnectionSettings(
            profiles: [],
            width: 393,
            height: 852,
            dynamicTypeSize: .accessibility2,
            named: "unconfigured-compact-accessibility"
        )
    }

    func testUnconfiguredConnectionSettingsOnWideWidthInDarkAppearance() {
        assertConnectionSettings(
            profiles: [],
            width: 720,
            height: 1_000,
            colorScheme: .dark,
            named: "unconfigured-wide-dark"
        )
    }

    func testSingleUnavailableConnectionKeepsRecoveryActionsVisible() {
        assertConnectionSettings(
            profiles: [
                makeProfile(
                    id: "linux-server",
                    name: "Linux 工作站",
                    endpoint: "http://100.64.0.10:8787",
                    dnsName: "linux-server.tail.example.ts.net",
                    deviceName: "linux-server",
                    platform: .linux
                )
            ],
            width: 393,
            height: 852,
            connectionStatus: .failed("快照中的电脑当前不可用"),
            named: "single-unavailable"
        )
    }

    func testSingleConnectedComputerOnCompactWidth() {
        assertConnectionSettings(
            profiles: [
                makeProfile(
                    id: "studio-mac",
                    name: "工作室 Mac",
                    endpoint: "http://100.64.0.10:8787",
                    dnsName: "studio-mac.tail.example.ts.net",
                    deviceName: "studio-mac",
                    platform: .apple
                )
            ],
            width: 393,
            height: 852,
            colorScheme: .dark,
            connectionStatus: .connected("snapshot"),
            named: "single-connected-compact"
        )
    }

    /// 与设备首页的日常场景一致：当前电脑、另一台已保存电脑和偏好设置同屏出现。
    func testConnectedAndSavedComputersOnCompactWidth() {
        assertConnectionSettings(
            profiles: [
                makeProfile(
                    id: "studio-mac",
                    name: "工作室 Mac",
                    endpoint: "http://100.64.0.10:8787",
                    dnsName: "studio-mac.tail.example.ts.net",
                    deviceName: "studio-mac",
                    platform: .apple
                ),
                makeProfile(
                    id: "linux-server",
                    name: "Linux 工作站",
                    endpoint: "http://100.64.0.20:8787",
                    dnsName: "linux-server.tail.example.ts.net",
                    deviceName: "linux-server",
                    platform: .linux
                )
            ],
            width: 393,
            height: 852,
            colorScheme: .dark,
            connectionStatus: .connected("snapshot"),
            named: "connected-and-saved-compact"
        )
    }

    /// 浅色下三组的标题线、当前电脑的选中底色，以及线路行的结论（固定一条探测结果，不走网络）。
    func testConnectedComputerShowsRouteSummaryInLightAppearance() {
        assertConnectionSettings(
            profiles: [
                makeProfile(
                    id: "studio-mac",
                    name: "工作室 Mac",
                    endpoint: "http://100.64.0.10:8787",
                    dnsName: "studio-mac.tail.example.ts.net",
                    deviceName: "studio-mac",
                    platform: .apple
                ),
                makeProfile(
                    id: "linux-server",
                    name: "Linux 工作站",
                    endpoint: "http://100.64.0.20:8787",
                    dnsName: "linux-server.tail.example.ts.net",
                    deviceName: "linux-server",
                    platform: .linux
                )
            ],
            width: 393,
            height: 852,
            connectionStatus: .connected("snapshot"),
            routeProbe: FallbackRouteProbe(
                checkedAt: Date(timeIntervalSince1970: 1_785_105_600),
                pathKind: .derp,
                relayRegion: nil,
                httpMillis: 61,
                succeeded: true
            ),
            named: "connected-route-light"
        )
    }

    func testMultipleUnavailableConnectionsAtAccessibilitySize() {
        assertConnectionSettings(
            profiles: [
                makeProfile(
                    id: "studio-mac",
                    name: "工作室 Mac",
                    endpoint: "http://100.64.0.10:8787",
                    dnsName: "studio-mac.tail.example.ts.net",
                    deviceName: "studio-mac",
                    platform: .apple
                ),
                makeProfile(
                    id: "windows-pc",
                    name: "Windows 工作站",
                    endpoint: "http://100.64.0.20:8787",
                    dnsName: "windows-pc.tail.example.ts.net",
                    deviceName: "windows-pc",
                    platform: .windows
                )
            ],
            width: 720,
            height: 1_000,
            dynamicTypeSize: .accessibility2,
            connectionStatus: .failed("快照中的电脑当前不可用"),
            named: "multiple-unavailable-accessibility"
        )
    }

    private func assertConnectionSettings(
        profiles: [ConnectionProfile],
        width: CGFloat,
        height: CGFloat,
        dynamicTypeSize: DynamicTypeSize = .large,
        colorScheme: ColorScheme = .light,
        connectionStatus: ConnectionStatus? = nil,
        routeProbe: FallbackRouteProbe? = nil,
        named name: String,
        file: StaticString = #file,
        testName: String = #function,
        line: UInt = #line
    ) {
        let fixture = makeFixture(
            profiles: profiles,
            connectionStatus: connectionStatus
        )
        // 导航由真实入口持有；这里固定表单容器，独立验证分组、按钮和电脑行的布局。
        // 线路自动探测依赖网络耗时且结果带时间戳，快照里必须关掉，让线路行停在「未检测」；
        // 需要看线路结论时直接给草稿塞一条记在当前电脑名下的探测结果。
        let navigation = SettingsNavigationState()
        if let routeProbe {
            navigation.connectionDraft.routeProbeProfileID = profiles.first?.id
            navigation.connectionDraft.fallbackRouteProbe = routeProbe
        }
        let view = ConnectionSettingsView(
            qrScannerPresentation: fixture.qrScannerPresentation,
            navigation: navigation,
            probesRouteAutomatically: false
        )
        // 偏好使用独立存储，避免模拟器里上次手动选择污染视觉基线。
        .defaultAppStorage(fixture.defaults)
        .environmentObject(fixture.appStore)
        .environmentObject(fixture.sessionStore)
        .environmentObject(fixture.themeStore)
        .environmentObject(fixture.tailcatController)
        .environmentObject(fixture.lockScreenApprovalStore)
        .environment(\.colorScheme, colorScheme)
        .environment(\.dynamicTypeSize, dynamicTypeSize)
        .frame(width: width, height: height)

        if let failure = verifySnapshot(
            of: view,
            as: .wait(
                for: 0.5,
                on: .image(
                    drawHierarchyInKeyWindow: true,
                    precision: 0.98,
                    layout: .fixed(width: width, height: height)
                )
            ),
            named: name,
            snapshotDirectory: referenceSnapshotDirectory,
            file: file,
            testName: testName,
            line: line
        ) {
            XCTFail(failure, file: file, line: line)
        }
    }

    private func makeFixture(
        profiles: [ConnectionProfile],
        connectionStatus: ConnectionStatus?
    ) -> Fixture {
        let suiteName = "ConnectionSettingsSnapshotTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(try! JSONEncoder().encode(profiles), forKey: "agentd.connectionProfiles.v2")
        if let activeProfile = profiles.first {
            defaults.set(activeProfile.id, forKey: "agentd.activeConnectionProfileID.v1")
        }

        let keychain = TestKeychainOperations()
        let tokenStore = TokenStore(keychain: keychain)
        for profile in profiles {
            try! tokenStore.save("snapshot-token", profileID: profile.id)
        }

        let appStore = AppStore(
            defaults: defaults,
            tokenStore: tokenStore,
            prefersLocalConnection: false
        )
        if let connectionStatus {
            appStore.connectionStatus = connectionStatus
        }
        let tailcatController = TailcatExperimentController(
            appStore: appStore,
            defaults: defaults,
            tokenStore: tokenStore
        )
        let client = MockSessionStoreClient(projects: [], sessions: [])
        let sessionStore = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            tailcatExperimentController: tailcatController,
            clientFactory: { client }
        )

        let themeSuiteName = "ConnectionSettingsSnapshotTests.Theme.\(UUID().uuidString)"
        let themeDefaults = UserDefaults(suiteName: themeSuiteName)!
        themeDefaults.removePersistentDomain(forName: themeSuiteName)
        return Fixture(
            defaults: defaults,
            appStore: appStore,
            sessionStore: sessionStore,
            themeStore: ThemeStore(defaults: themeDefaults),
            tailcatController: tailcatController,
            lockScreenApprovalStore: LockScreenApprovalStore(
                defaults: defaults,
                ticketStore: PushTicketStore(keychain: keychain),
                identityStore: PushInstallationIdentityStore(keychain: keychain)
            ),
            qrScannerPresentation: ConnectionQRCodeScannerPresentation()
        )
    }

    private func makeProfile(
        id: String,
        name: String,
        endpoint: String,
        dnsName: String,
        deviceName: String,
        platform: HostPlatform
    ) -> ConnectionProfile {
        ConnectionProfile(
            id: id,
            displayName: name,
            endpoint: endpoint,
            tailscaleDNSName: dnsName,
            tailscaleDeviceName: deviceName,
            lastSuccessfulAt: Date(timeIntervalSince1970: 1_785_105_600),
            installationID: "installation-\(id)",
            hostPlatform: platform
        )
    }

    private var referenceSnapshotDirectory: String? {
        #if targetEnvironment(simulator)
        nil
        #else
        Bundle(for: Self.self).bundlePath
        #endif
    }
}

@MainActor
private struct Fixture {
    let defaults: UserDefaults
    let appStore: AppStore
    let sessionStore: SessionStore
    let themeStore: ThemeStore
    let tailcatController: TailcatExperimentController
    let lockScreenApprovalStore: LockScreenApprovalStore
    let qrScannerPresentation: ConnectionQRCodeScannerPresentation
}
