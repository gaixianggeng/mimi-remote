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
}
