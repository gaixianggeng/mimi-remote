import SnapshotTesting
import SwiftUI
import UIKit
import XCTest
@testable import MimiRemote

/// 连接卡片是「我的」页首屏唯一的状态模块，正常与异常必须一眼可分。
@MainActor
final class SettingsConnectionCardSnapshotTests: XCTestCase {
    private let cardWidth: CGFloat = 361

    override func setUpWithError() throws {
        try super.setUpWithError()
        try SnapshotTestEnvironment.requireFixedSimulator()
    }

    func testConnectedStateStaysQuiet() {
        let themeStore = makeThemeStore()
        let tokens = themeStore.tokens(for: .light)

        assert(
            SettingsConnectionCard(
                deviceName: "landy 的 MacBook Pro",
                status: "已连接",
                savedDeviceCount: 3,
                statusTint: tokens.success,
                warningText: nil
            )
            .padding(16)
            .background(tokens.background)
            .environmentObject(themeStore)
            .environment(\.colorScheme, .light)
            .frame(width: cardWidth)
            .fixedSize(horizontal: false, vertical: true),
            named: "connected-compact"
        )
    }

    /// 断线提示过去挂在「更多」分组的 footer，显示在「关于与法律」下面。
    /// 现在必须和它描述的设备出现在同一张卡片里。
    func testDisconnectedStateCarriesWarningInsideCard() {
        let themeStore = makeThemeStore()
        let tokens = themeStore.tokens(for: .light)

        assert(
            SettingsConnectionCard(
                deviceName: "landy 的 MacBook Pro",
                status: "网络不可用",
                savedDeviceCount: 3,
                statusTint: tokens.warning,
                warningText: "网络不可用，同步已暂停。恢复网络后会自动重连。"
            )
            .padding(16)
            .background(tokens.background)
            .environmentObject(themeStore)
            .environment(\.colorScheme, .light)
            .frame(width: cardWidth)
            .fixedSize(horizontal: false, vertical: true),
            named: "disconnected-compact"
        )
    }

    func testConnectedStateInDarkAppearance() {
        let themeStore = makeThemeStore()
        let tokens = themeStore.tokens(for: .dark)

        assert(
            SettingsConnectionCard(
                deviceName: "landy 的 MacBook Pro",
                status: "已连接",
                savedDeviceCount: 3,
                statusTint: tokens.success,
                warningText: nil
            )
            .padding(16)
            .background(tokens.background)
            .environmentObject(themeStore)
            .environment(\.colorScheme, .dark)
            .frame(width: cardWidth)
            .fixedSize(horizontal: false, vertical: true),
            named: "connected-dark"
        )
    }

    func testConnectionDiagnosticsNetworkPathKeepsIntrinsicHeightInsideExpandedForm() throws {
        let previousLanguage = UserDefaults.standard.string(forKey: AppLanguage.preferenceKey)
        UserDefaults.standard.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppLanguage.preferenceKey)
        defer {
            if let previousLanguage {
                UserDefaults.standard.set(previousLanguage, forKey: AppLanguage.preferenceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AppLanguage.preferenceKey)
            }
        }

        let networkPath = try AgentAPIClient.decoder.decode(
            TailscaleNetworkPathResponse.self,
            from: Data(
                #"{"kind":"derp","observed_at":"2026-08-30T10:00:00Z","relay_region":"NUE"}"#.utf8
            )
        )

        let view = Form {
            Section {
                DisclosureGroup(isExpanded: .constant(true)) {
                    LabeledContent("测试耗时", value: "17 秒")
                    ConnectionDiagnosticsNetworkPathRow(networkPath: networkPath)
                    HStack {
                        Text("最慢环节")
                        Spacer()
                        Text("基础连通 · 11 秒")
                            .foregroundStyle(.orange)
                    }
                    HStack {
                        Text("最近波动")
                        Spacer()
                        Text("基础连通 · 7 次采样")
                    }
                } label: {
                    Text("连接诊断")
                }
            }
        }
        .frame(width: 393, height: 852)
        .environment(\.dynamicTypeSize, .large)

        assertFixed(view, named: "diagnostics-network-path-intrinsic-height", width: 393, height: 852)

        let compactView = Form {
            Section {
                ConnectionDiagnosticsNetworkPathRow(networkPath: networkPath)
            }
        }
        .frame(width: 393, height: 180)
        .environment(\.dynamicTypeSize, .large)

        assertFixed(compactView, named: "diagnostics-network-path-single-line", width: 393, height: 180)
    }

    private func makeThemeStore() -> ThemeStore {
        let suite = "SettingsConnectionCardSnapshotTests.Theme.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return ThemeStore(defaults: defaults)
    }

    private func assert<V: View>(
        _ view: V,
        named name: String,
        file: StaticString = #file,
        testName: String = #function,
        line: UInt = #line
    ) {
        if let failure = verifySnapshot(
            of: view,
            as: .wait(
                for: 0.5,
                on: .image(
                    drawHierarchyInKeyWindow: true,
                    precision: 0.98,
                    layout: .sizeThatFits
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

    private func assertFixed<V: View>(
        _ view: V,
        named name: String,
        width: CGFloat,
        height: CGFloat,
        file: StaticString = #file,
        testName: String = #function,
        line: UInt = #line
    ) {
        if let failure = verifySnapshot(
            of: view,
            as: .image(
                drawHierarchyInKeyWindow: true,
                precision: 0.99,
                layout: .fixed(width: width, height: height)
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

    private var referenceSnapshotDirectory: String? {
        #if targetEnvironment(simulator)
        // 模拟器保留源码目录路径，方便本地重新录制基线。
        nil
        #else
        // 真机不能访问 Mac 源码目录；Xcode 会把基线平铺复制进测试 Bundle。
        Bundle(for: Self.self).bundlePath
        #endif
    }
}
