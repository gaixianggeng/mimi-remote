import XCTest
@testable import MimiRemoteMac

@MainActor
extension HostStoreTests {
    func testBootstrapRequestsPhotoAuthorizationBeforeRegisteringAgent() async {
        let events = EventRecorder()
        var authorization = PhotoLibraryAuthorization.notDetermined
        let store = makeStore(
            configExists: true,
            registerAgent: { events.append("register-mac") },
            photoLibraryAccess: PhotoLibraryAccessClient(
                authorizationStatus: { authorization },
                requestAuthorization: {
                    events.append("request-photos")
                    authorization = .authorized
                    return authorization
                },
                openPhotosPrivacySettings: {},
                openFullDiskAccessSettings: {}
            )
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, ["request-photos", "register-mac"])
        XCTAssertEqual(store.photoLibraryAuthorization, .authorized)
        XCTAssertEqual(store.lifecycle, .ready)
    }

    func testDeniedPhotoAuthorizationDoesNotBlockAgentStartup() async {
        let events = EventRecorder()
        let store = makeStore(
            configExists: true,
            registerAgent: { events.append("register-mac") },
            photoLibraryAccess: PhotoLibraryAccessClient(
                authorizationStatus: { .notDetermined },
                requestAuthorization: {
                    events.append("request-photos")
                    return .denied
                },
                openPhotosPrivacySettings: {},
                openFullDiskAccessSettings: {}
            )
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, ["request-photos", "register-mac"])
        XCTAssertEqual(store.photoLibraryAuthorization, .denied)
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertNil(store.lastError)
    }

    func testBootstrapWithoutConfigurationDoesNotRequestPhotoAuthorization() async {
        let events = EventRecorder()
        let store = makeStore(
            configExists: false,
            photoLibraryAccess: PhotoLibraryAccessClient(
                authorizationStatus: { .notDetermined },
                requestAuthorization: {
                    events.append("request-photos")
                    return .authorized
                },
                openPhotosPrivacySettings: {},
                openFullDiskAccessSettings: {}
            )
        )

        await store.bootstrap()

        XCTAssertTrue(events.values.isEmpty)
        XCTAssertEqual(store.lifecycle, .notConfigured)
    }

    func testTakeoverRequestsPhotoAuthorizationBeforeStoppingHomebrew() async {
        let events = EventRecorder()
        let store = makeStore(
            configExists: true,
            homebrewLoaded: true,
            registerAgent: { events.append("register-mac") },
            homebrewStop: { events.append("stop-homebrew") },
            photoLibraryAccess: PhotoLibraryAccessClient(
                authorizationStatus: { .notDetermined },
                requestAuthorization: {
                    events.append("request-photos")
                    return .authorized
                },
                openPhotosPrivacySettings: {},
                openFullDiskAccessSettings: {}
            )
        )
        await store.bootstrap()

        await store.takeOverHomebrew()

        XCTAssertEqual(events.values, ["request-photos", "stop-homebrew", "register-mac"])
        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertNotNil(store.pairing)
    }
}
