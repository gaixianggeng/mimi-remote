import XCTest
@testable import MimiRemote

@MainActor
final class ConnectionSettingsDraftTests: XCTestCase {
    func testUnchangedConnectionPreservesUncommittedInput() {
        let draft = ConnectionSettingsDraft()
        draft.reloadIfConnectionChanged(profileID: "profile-a", endpoint: "https://old.example", token: "old-token")
        draft.endpoint = "https://typing.example"
        draft.token = "typing-token"
        draft.isAddingConnectionProfile = true
        draft.profileDisplayName = "New Mac"
        draft.isShowingAdvancedManualConnection = true

        let didReload = draft.reloadIfConnectionChanged(
            profileID: "profile-a",
            endpoint: "https://old.example",
            token: "old-token"
        )

        XCTAssertFalse(didReload)
        XCTAssertEqual(draft.endpoint, "https://typing.example")
        XCTAssertEqual(draft.token, "typing-token")
        XCTAssertTrue(draft.isAddingConnectionProfile)
        XCTAssertEqual(draft.profileDisplayName, "New Mac")
        XCTAssertTrue(draft.isShowingAdvancedManualConnection)
    }

    func testChangedCredentialsReplaceAndInvalidateOldDraft() {
        let draft = ConnectionSettingsDraft()
        draft.reloadIfConnectionChanged(profileID: "profile-a", endpoint: "https://old.example", token: "old-token")
        draft.endpoint = "https://typing.example"
        draft.token = "typing-token"
        draft.isAddingConnectionProfile = true
        draft.profileDisplayName = "New Mac"
        draft.isShowingAdvancedManualConnection = true
        draft.localError = "Old error"
        draft.addComputerError = "Old add error"

        let didReload = draft.reloadIfConnectionChanged(
            profileID: "profile-a",
            endpoint: "https://current.example",
            token: "current-token"
        )

        XCTAssertTrue(didReload)
        XCTAssertEqual(draft.endpoint, "https://current.example")
        XCTAssertEqual(draft.token, "current-token")
        XCTAssertFalse(draft.isAddingConnectionProfile)
        XCTAssertEqual(draft.profileDisplayName, "")
        XCTAssertFalse(draft.isShowingAdvancedManualConnection)
        XCTAssertNil(draft.localError)
        XCTAssertNil(draft.addComputerError)
    }

    func testChangedProfileInvalidatesDraftEvenWhenCredentialsMatch() {
        let draft = ConnectionSettingsDraft()
        draft.reloadIfConnectionChanged(profileID: "profile-a", endpoint: "https://same.example", token: "same-token")
        draft.endpoint = "https://typing.example"

        let didReload = draft.reloadIfConnectionChanged(
            profileID: "profile-b",
            endpoint: "https://same.example",
            token: "same-token"
        )

        XCTAssertTrue(didReload)
        XCTAssertEqual(draft.endpoint, "https://same.example")
    }

    func testAddComputerErrorSurvivesLayoutRebuildButNewFlowClearsIt() {
        let navigation = SettingsNavigationState()
        let draft = navigation.connectionDraft
        draft.localError = "Failed to switch saved Mac"
        draft.addComputerError = "Old add error"

        navigation.devicePath = [.addComputer]
        XCTAssertNil(draft.addComputerError)
        XCTAssertEqual(draft.localError, "Failed to switch saved Mac")

        draft.addComputerError = "Clipboard has no connection link"
        // 布局重建仍持有同一导航路径，设备页迟到的失败也不能改写添加页反馈。
        navigation.devicePath = [.addComputer]
        draft.localError = "Late switch failure"
        XCTAssertEqual(draft.addComputerError, "Clipboard has no connection link")

        navigation.devicePath = []
        navigation.devicePath = [.addComputer]
        XCTAssertNil(draft.addComputerError)
        XCTAssertEqual(draft.localError, "Late switch failure")
    }

    func testRootWorkbenchPresentationKeepsTabBarAfterForgettingComputer() {
        var presentation = RootWorkbenchPresentation()

        // 首次启动且无已保存电脑时，保留首次连接引导页作为根页面。
        XCTAssertFalse(
            presentation.showsWorkbench(
                canEnterWorkbench: false,
                hasSavedProfiles: false,
                isInitialSetupScannerPresented: false
            )
        )

        // 首次扫码配对提交凭据后，等全屏扫码 Cover 关闭再切入工作台。
        XCTAssertFalse(
            presentation.showsWorkbench(
                canEnterWorkbench: true,
                hasSavedProfiles: true,
                isInitialSetupScannerPresented: true
            )
        )
        presentation.synchronize(
            canEnterWorkbench: true,
            hasSavedProfiles: true,
            isInitialSetupScannerPresented: true
        )
        XCTAssertFalse(presentation.hasEnteredWorkbench)

        // 扫码 Cover 关闭后立即进入工作台并显示底部 Tab 栏。
        XCTAssertTrue(
            presentation.showsWorkbench(
                canEnterWorkbench: true,
                hasSavedProfiles: true,
                isInitialSetupScannerPresented: false
            )
        )
        presentation.synchronize(
            canEnterWorkbench: true,
            hasSavedProfiles: true,
            isInitialSetupScannerPresented: false
        )
        XCTAssertTrue(presentation.hasEnteredWorkbench)

        // 忘记最后一台电脑后不再踢出工作台，底部 Tab 栏继续保留。
        XCTAssertTrue(
            presentation.showsWorkbench(
                canEnterWorkbench: false,
                hasSavedProfiles: false,
                isInitialSetupScannerPresented: false
            )
        )
    }

    func testRootWorkbenchPresentationEntersWorkbenchWhenSavedProfilesExist() {
        let presentation = RootWorkbenchPresentation()

        // 冷启动时当前档案凭据缺失但本地仍有已保存电脑，应进入工作台（含 Tab 栏）并落在设备页恢复。
        XCTAssertTrue(
            presentation.showsWorkbench(
                canEnterWorkbench: false,
                hasSavedProfiles: true,
                isInitialSetupScannerPresented: false
            )
        )
    }

    func testPairingCompletionResolutionCoversAllEntryModes() {
        // 首次连接扫码 Mimi 二维码：等 Cover 关闭后交给工作台接续中转配置。
        let firstMimiScan = PendingConnectionPairingCompletion.resolve(
            wasConfigured: false,
            isPresentedInScanner: true,
            wantsMimiRelaySetup: true,
            mode: .deviceHome,
            isPresentedInSettingsSheet: false,
            activeProfileID: "mac-1"
        )
        XCTAssertFalse(firstMimiScan.opensManagedConnectionInStack)
        XCTAssertEqual(firstMimiScan.deferredMimiRelaySetupProfileID, "mac-1")

        // 工作台添加电脑页扫 Mimi 二维码：退出添加页后由工作台推入中转页，避免返回再落回添加页。
        let addComputerMimiScan = PendingConnectionPairingCompletion.resolve(
            wasConfigured: true,
            isPresentedInScanner: true,
            wantsMimiRelaySetup: true,
            mode: .addComputer,
            isPresentedInSettingsSheet: false,
            activeProfileID: "mac-2"
        )
        XCTAssertFalse(addComputerMimiScan.opensManagedConnectionInStack)
        XCTAssertEqual(addComputerMimiScan.deferredMimiRelaySetupProfileID, "mac-2")

        // 粘贴普通配对链接：直接完成返回，不触发中转配置。
        let addComputerPaste = PendingConnectionPairingCompletion.resolve(
            wasConfigured: true,
            isPresentedInScanner: false,
            wantsMimiRelaySetup: false,
            mode: .addComputer,
            isPresentedInSettingsSheet: false,
            activeProfileID: "mac-2"
        )
        XCTAssertFalse(addComputerPaste.opensManagedConnectionInStack)
        XCTAssertNil(addComputerPaste.deferredMimiRelaySetupProfileID)

        // 设置 sheet 中重新配对扫码 Mimi 二维码：在当前栈推出中转页。
        let repairSheetMimiScan = PendingConnectionPairingCompletion.resolve(
            wasConfigured: true,
            isPresentedInScanner: true,
            wantsMimiRelaySetup: true,
            mode: .deviceHome,
            isPresentedInSettingsSheet: true,
            activeProfileID: "mac-1"
        )
        XCTAssertTrue(repairSheetMimiScan.opensManagedConnectionInStack)
        XCTAssertNil(repairSheetMimiScan.deferredMimiRelaySetupProfileID)
    }

    func testPendingPairingCompletionSurvivesConnectionReloadUntilClearedByNewFlow() {
        let draft = ConnectionSettingsDraft()
        let completion = PendingConnectionPairingCompletion(
            opensManagedConnectionInStack: false,
            deferredMimiRelaySetupProfileID: "mac-2"
        )
        draft.pendingPairingCompletion = completion

        let didReload = draft.reloadIfConnectionChanged(
            profileID: "mac-2",
            endpoint: "https://new.example",
            token: "new-token"
        )

        XCTAssertTrue(didReload)
        XCTAssertEqual(
            draft.pendingPairingCompletion,
            completion,
            "扫码提交新凭据会触发草稿重载，但必须保留待收尾动作直到 Cover 关闭"
        )

        draft.beginAddingComputer()
        XCTAssertNil(draft.pendingPairingCompletion)
    }

    func testManagedSubscriptionSelectsMimiOnlyForTailcatRoutes() {
        XCTAssertTrue(ManagedConnectionSubscriptionView.shouldSelectMimiAfterPairing(route: .customTailcat))
        XCTAssertTrue(ManagedConnectionSubscriptionView.shouldSelectMimiAfterPairing(route: .managedTailcat))
        XCTAssertFalse(ManagedConnectionSubscriptionView.shouldSelectMimiAfterPairing(route: .lan))
        XCTAssertFalse(ManagedConnectionSubscriptionView.shouldSelectMimiAfterPairing(route: .tailscale))
        XCTAssertFalse(ManagedConnectionSubscriptionView.shouldSelectMimiAfterPairing(route: nil))
    }
}
