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

    func testSingleUnavailableConnectionKeepsRecoveryActionsVisible() {
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
            named: "single-unavailable"
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
                    id: "travel-mac",
                    name: "随身 MacBook Air",
                    endpoint: "http://100.64.0.20:8787",
                    dnsName: "travel-mac.tail.example.ts.net",
                    deviceName: "travel-mac",
                    platform: .apple
                )
            ],
            width: 720,
            height: 1_000,
            dynamicTypeSize: .accessibility2,
            named: "multiple-unavailable-accessibility"
        )
    }

    private func assertConnectionSettings(
        profiles: [ConnectionProfile],
        width: CGFloat,
        height: CGFloat,
        dynamicTypeSize: DynamicTypeSize = .large,
        named name: String,
        file: StaticString = #file,
        testName: String = #function,
        line: UInt = #line
    ) {
        let fixture = makeFixture(profiles: profiles)
        // 导航由真实入口持有；这里固定表单容器，独立验证分组、按钮和电脑行的布局。
        let view = ConnectionSettingsView(
            qrScannerPresentation: fixture.qrScannerPresentation,
            onRequestProfileRename: { _ in }
        )
        .environmentObject(fixture.appStore)
        .environmentObject(fixture.sessionStore)
        .environmentObject(fixture.themeStore)
        .environmentObject(fixture.tailcatController)
        .environment(\.colorScheme, .light)
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

    private func makeFixture(profiles: [ConnectionProfile]) -> Fixture {
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
        if !profiles.isEmpty {
            appStore.connectionStatus = .failed("快照中的电脑当前不可用")
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
            appStore: appStore,
            sessionStore: sessionStore,
            themeStore: ThemeStore(defaults: themeDefaults),
            tailcatController: tailcatController,
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
    let appStore: AppStore
    let sessionStore: SessionStore
    let themeStore: ThemeStore
    let tailcatController: TailcatExperimentController
    let qrScannerPresentation: ConnectionQRCodeScannerPresentation
}
