import XCTest
@testable import MimiRemoteMac

final class AppReleaseTests: XCTestCase {
    func testVersionsCompareNumericallyAndRejectNonReleaseStrings() {
        XCTAssertLessThan(AppReleaseVersion("0.3.9")!, AppReleaseVersion("0.3.13")!)
        XCTAssertLessThan(AppReleaseVersion("0.9.99")!, AppReleaseVersion("0.10.0")!)
        XCTAssertLessThan(AppReleaseVersion("0.99.99")!, AppReleaseVersion("1.0.0")!)
        XCTAssertEqual(AppReleaseVersion("0.3.13"), AppReleaseVersion("0.3.13"))
        for value in ["", "v0.3.13", "0.3", "0.3.13-beta.1", "0.3.13+dev", "-1.3.0", "1..0"] {
            XCTAssertNil(AppReleaseVersion(value), value)
        }
    }

    func testOnlyUploadedOfficialMacAssetIsAccepted() throws {
        let release = try MacAppRelease.decode(releaseData())
        XCTAssertEqual(release.version, "0.3.14")
        XCTAssertEqual(release.downloadURL.absoluteString, Self.download)
        for overrides: [String: Any] in [
            ["prerelease": true], ["draft": true], ["tag_name": "v0.3.14-beta.1"],
            ["assets": []],
            ["assets": [["name": "Mimi-Remote-Mac.dmg", "state": "new", "browser_download_url": Self.download]]],
            ["assets": [["name": "Mimi-Remote-Mac.dmg", "state": "uploaded", "browser_download_url": "https://example.com/app.dmg"]]],
            ["assets": [["name": "windows.exe", "state": "uploaded", "browser_download_url": Self.download]]]
        ] {
            XCTAssertThrowsError(try MacAppRelease.decode(releaseData(overrides: overrides)))
        }
    }

    func testMalformedResponseIsRejected() {
        XCTAssertThrowsError(try MacAppRelease.decode(Data("{}".utf8)))
    }

    private static let download = "https://github.com/gaixianggeng/mimi-remote/releases/download/v0.3.14/Mimi-Remote-Mac.dmg"

    private func releaseData(overrides: [String: Any] = [:]) -> Data {
        var object: [String: Any] = [
            "tag_name": "v0.3.14", "draft": false, "prerelease": false,
            "assets": [["name": "Mimi-Remote-Mac.dmg", "state": "uploaded", "browser_download_url": Self.download]]
        ]
        object.merge(overrides) { _, new in new }
        return try! JSONSerialization.data(withJSONObject: object)
    }
}

@MainActor
final class AppUpdateStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "AppUpdateStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testManualCheckOffersNewerVersionAndDoesNotOfferDowngrade() async {
        for (installed, hasUpdate) in [("0.3.9", true), ("0.3.14", false), ("0.4.0", false)] {
            let store = makeStore(currentVersion: installed)
            await store.check(manual: true)
            XCTAssertEqual(store.availableRelease != nil, hasUpdate)
            XCTAssertEqual(store.showsUpdateNotice, hasUpdate)
            XCTAssertEqual(store.statusMessage == nil, hasUpdate)
            XCTAssertNil(store.errorMessage)
            XCTAssertFalse(store.isChecking)
        }
    }

    func testAutomaticCheckIsThrottledButManualCheckCanRetry() async {
        var calls = 0
        let store = makeStore(client: AppUpdateClient {
            calls += 1
            throw AppUpdateError.requestFailed
        })
        let start = Date(timeIntervalSince1970: 100_000)
        await store.check(manual: false, now: start)
        await store.check(manual: false, now: start.addingTimeInterval(60))
        XCTAssertEqual(calls, 1)
        XCTAssertNil(store.errorMessage)
        await store.check(manual: true, now: start.addingTimeInterval(120))
        XCTAssertEqual(calls, 2)
        XCTAssertNotNil(store.errorMessage)
        await store.check(manual: false, now: start.addingTimeInterval(120 + AppUpdateStore.checkInterval))
        XCTAssertEqual(calls, 3)
    }

    func testDeferredVersionSurvivesRestartAndNewVersionShowsAgain() async {
        let first = makeStore()
        await first.check(manual: false)
        first.deferUpdate()
        XCTAssertFalse(first.showsUpdateNotice)
        XCTAssertNotNil(first.availableRelease)
        let restarted = makeStore()
        await restarted.check(manual: true)
        XCTAssertFalse(restarted.showsUpdateNotice)
        XCTAssertNotNil(restarted.availableRelease, "稍后不应移除手动下载入口")
        let next = makeStore(client: AppUpdateClient { Self.release("0.3.15") })
        await next.check(manual: false)
        XCTAssertTrue(next.showsUpdateNotice)
    }

    func testFailurePreservesKnownUpdateAndSuccessClearsError() async {
        var fail = false
        let store = makeStore(client: AppUpdateClient {
            if fail { throw AppUpdateError.requestFailed }
            return Self.release("0.3.14")
        })
        await store.check(manual: true)
        fail = true
        await store.check(manual: true)
        XCTAssertNotNil(store.availableRelease)
        XCTAssertNotNil(store.errorMessage)
        fail = false
        await store.check(manual: true)
        XCTAssertNil(store.errorMessage)
    }

    func testUnknownCurrentVersionDoesNotClaimUpToDate() async {
        let store = makeStore(currentVersion: "dev")
        await store.check(manual: true)
        XCTAssertNil(store.statusMessage)
        XCTAssertNil(store.availableRelease)
        XCTAssertNotNil(store.errorMessage)
    }

    func testOverlappingChecksOnlyMakeOneRequest() async {
        var continuation: CheckedContinuation<MacAppRelease, Error>?
        let store = makeStore(client: AppUpdateClient {
            try await withCheckedThrowingContinuation { continuation = $0 }
        })
        let task = Task { await store.check(manual: true) }
        while continuation == nil { await Task.yield() }
        XCTAssertTrue(store.isChecking)
        await store.check(manual: true)
        continuation?.resume(returning: Self.release("0.3.14"))
        await task.value
        XCTAssertFalse(store.isChecking)
        XCTAssertTrue(store.showsUpdateNotice)
    }

    private func makeStore(currentVersion: String = "0.3.13", client: AppUpdateClient? = nil) -> AppUpdateStore {
        AppUpdateStore(
            currentVersion: currentVersion,
            client: client ?? AppUpdateClient { Self.release("0.3.14") },
            defaults: defaults
        )
    }

    private static func release(_ version: String) -> MacAppRelease {
        MacAppRelease(
            version: version,
            downloadURL: URL(string: "https://github.com/gaixianggeng/mimi-remote/releases/download/v\(version)/Mimi-Remote-Mac.dmg")!,
            releaseURL: URL(string: "https://github.com/gaixianggeng/mimi-remote/releases/tag/v\(version)")!
        )
    }
}

final class AppUpdateClientTests: XCTestCase {
    func testHTTPErrorWithReleaseShapedBodyIsNotAccepted() async {
        let session = makeSession(status: 403)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await AppUpdateClient.live(session: session).latestRelease()
            XCTFail("HTTP 403 不应提供更新")
        } catch {
            XCTAssertTrue(error is AppUpdateError)
        }
    }

    func testPublicRequestUsesCorrectEndpointAndNoCredentials() async throws {
        let session = makeSession(status: 200)
        defer { session.invalidateAndCancel() }
        let release = try await AppUpdateClient.live(session: session).latestRelease()
        XCTAssertEqual(release.version, "0.3.14")
    }

    private func makeSession(status: Int) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdateURLProtocol.self]
        config.httpAdditionalHeaders = ["X-Test-Status": String(status)]
        return URLSession(configuration: config)
    }
}

private final class UpdateURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/gaixianggeng/mimi-remote/releases/latest")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        let status = Int(request.value(forHTTPHeaderField: "X-Test-Status") ?? "200")!
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        let body = """
        {"tag_name":"v0.3.14","draft":false,"prerelease":false,"assets":[
          {"name":"Mimi-Remote-Mac.dmg","state":"uploaded",
           "browser_download_url":"https://github.com/gaixianggeng/mimi-remote/releases/download/v0.3.14/Mimi-Remote-Mac.dmg"}
        ]}
        """
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
