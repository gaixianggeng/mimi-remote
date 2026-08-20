import XCTest
@testable import MimiRemoteMac

@MainActor
extension HostStoreTests {
    func testBootstrapWithEnabledCodexDesktopPreferenceRequestsPhotoAuthorizationBeforeRegisteringAgent() async {
        let events = EventRecorder()
        let store = makeStore(
            configExists: true,
            registerAgent: { events.append("register-mac") },
            codexDesktop: makeCodexDesktopClient(initialEnabled: true),
            photoLibraryAccess: photoLibraryAccess(
                authorization: .notDetermined,
                requestedAuthorization: .authorized,
                events: events
            )
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, ["request-photos", "register-mac"])
        XCTAssertEqual(store.photoLibraryAuthorization, .authorized)
        XCTAssertEqual(store.lifecycle, .ready)
    }

    func testDeniedPhotoAuthorizationDoesNotBlockCodexDesktopEnable() async {
        let events = EventRecorder()
        let store = makeStore(
            configExists: true,
            status: { Self.statusWithCodex(shared: true) },
            registerAgent: { events.append("register-mac") },
            configureCodexSharing: { enabled in
                events.append("configure-sharing-\(enabled)")
                return CodexSharingConfigurationResult(
                    enabled: enabled,
                    transport: "unix",
                    codexHome: "/tmp/codex"
                )
            },
            codexDesktop: makeCodexDesktopClient(initialEnabled: false, events: events),
            photoLibraryAccess: photoLibraryAccess(
                authorization: .notDetermined,
                requestedAuthorization: .denied,
                events: events
            )
        )

        await store.bootstrap()
        await store.setCodexDesktopEnabled(true)

        XCTAssertEqual(
            events.values,
            ["register-mac", "request-photos", "configure-sharing-true", "set-desktop-true"]
        )
        XCTAssertEqual(store.photoLibraryAuthorization, .denied)
        XCTAssertTrue(store.codexDesktopEnabled)
        XCTAssertNil(store.codexDesktopError)
        XCTAssertEqual(store.lifecycle, .ready)
    }

    func testBootstrapWithoutConfigurationDoesNotRequestPhotoAuthorization() async {
        let events = EventRecorder()
        let store = makeStore(
            configExists: false,
            photoLibraryAccess: photoLibraryAccess(
                authorization: .notDetermined,
                events: events
            )
        )

        await store.bootstrap()

        XCTAssertTrue(events.values.isEmpty)
        XCTAssertEqual(store.lifecycle, .notConfigured)
    }

    func testBootstrapWithDisabledCodexDesktopPreferenceDoesNotRequestPhotoAuthorization() async {
        let events = EventRecorder()
        let store = makeStore(
            configExists: true,
            registerAgent: { events.append("register-mac") },
            codexDesktop: makeCodexDesktopClient(initialEnabled: false),
            photoLibraryAccess: photoLibraryAccess(
                authorization: .notDetermined,
                events: events
            )
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, ["register-mac"])
        XCTAssertEqual(store.photoLibraryAuthorization, .notDetermined)
        XCTAssertEqual(store.lifecycle, .ready)
    }

    func testTakeoverDoesNotRequestPhotoAuthorizationBeforeStoppingHomebrew() async {
        let events = EventRecorder()
        let store = makeStore(
            configExists: true,
            homebrewLoaded: true,
            registerAgent: { events.append("register-mac") },
            homebrewStop: { events.append("stop-homebrew") },
            photoLibraryAccess: photoLibraryAccess(
                authorization: .notDetermined,
                events: events
            )
        )
        await store.bootstrap()

        await store.takeOverHomebrew()

        XCTAssertEqual(events.values, ["stop-homebrew", "register-mac"])
        XCTAssertEqual(store.photoLibraryAuthorization, .notDetermined)
        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertNotNil(store.pairing)
    }

    func testTakeoverWithEnabledCodexDesktopPreferenceRequestsPhotoAuthorizationBeforeRegisteringAgent() async {
        let events = EventRecorder()
        let store = makeStore(
            configExists: true,
            homebrewLoaded: true,
            registerAgent: { events.append("register-mac") },
            homebrewStop: { events.append("stop-homebrew") },
            codexDesktop: makeCodexDesktopClient(initialEnabled: true),
            photoLibraryAccess: photoLibraryAccess(
                authorization: .notDetermined,
                requestedAuthorization: .authorized,
                events: events
            )
        )
        await store.bootstrap()

        await store.takeOverHomebrew()

        XCTAssertEqual(events.values, ["stop-homebrew", "request-photos", "register-mac"])
        XCTAssertEqual(store.photoLibraryAuthorization, .authorized)
        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .ready)
    }

    func testDisablingCodexDesktopDoesNotRequestPhotoAuthorization() async {
        let events = EventRecorder()
        let store = makeStore(
            configExists: true,
            status: { Self.statusWithCodex(shared: false) },
            disableCodexSharingAfterDesktopExit: {
                CodexSharingConfigurationResult(enabled: false, transport: "unix")
            },
            codexDesktop: makeCodexDesktopClient(initialEnabled: false),
            photoLibraryAccess: photoLibraryAccess(
                authorization: .notDetermined,
                events: events
            )
        )

        await store.bootstrap()
        await store.setCodexDesktopEnabled(false)

        XCTAssertFalse(events.values.contains("request-photos"))
        XCTAssertEqual(store.photoLibraryAuthorization, .notDetermined)
        XCTAssertFalse(store.codexDesktopEnabled)
    }

    private func makeCodexDesktopClient(
        initialEnabled: Bool,
        events: EventRecorder? = nil
    ) -> CodexDesktopIntegrationClient {
        var enabled = initialEnabled
        let snapshot: () -> CodexDesktopEnvironmentSnapshot = {
            CodexDesktopEnvironmentSnapshot(
                hasLocalPreference: true,
                enabled: enabled,
                environmentValue: enabled ? "1" : nil,
                codexHome: enabled ? "/tmp/codex" : nil
            )
        }
        return CodexDesktopIntegrationClient(
            inspect: { snapshot() },
            bootstrap: { snapshot() },
            setEnabled: { next, _ in
                enabled = next
                events?.append("set-desktop-\(next)")
                return snapshot()
            },
            restartAndApply: { snapshot() }
        )
    }

    private func photoLibraryAccess(
        authorization: PhotoLibraryAuthorization,
        requestedAuthorization: PhotoLibraryAuthorization? = nil,
        events: EventRecorder
    ) -> PhotoLibraryAccessClient {
        PhotoLibraryAccessClient(
            authorizationStatus: { authorization },
            requestAuthorization: {
                events.append("request-photos")
                return requestedAuthorization ?? authorization
            },
            openPhotosPrivacySettings: {},
            openFullDiskAccessSettings: {}
        )
    }
}
