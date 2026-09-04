import Foundation
import XCTest
@testable import MimiRemote

final class ManagedConnectionDeviceAPIClientTests: XCTestCase {
    override func tearDown() {
        MIM260DeviceURLProtocol.reset()
        super.tearDown()
    }

    func testRegisterMobileSendsOnlyRandomIdentityAndDeviceToken() async throws {
        MIM260DeviceURLProtocol.respond(
            statusCode: 201,
            body: #"{"device":{"id":"device-id","deviceType":"mobile","createdAt":"2026-09-04T00:00:00.000Z"},"created":true}"#
        )
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = LiveManagedConnectionDeviceAPIClient(session: session)

        let result = try await client.registerMobileDevice(
            entitlementToken: "entitlement-token-that-is-long-enough",
            installationID: "10000000-0000-4000-8000-000000000001",
            deviceToken: Self.token(byte: 1)
        )

        let request = try XCTUnwrap(MIM260DeviceURLProtocol.capturedRequest())
        let body = try XCTUnwrap(MIM260DeviceURLProtocol.capturedBody())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(request.url?.absoluteString, "https://mimi.code89757.com/v1/devices")
        XCTAssertEqual(request.url?.path, "/v1/devices")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer entitlement-token-that-is-long-enough"
        )
        XCTAssertEqual(json["deviceType"], "mobile")
        XCTAssertEqual(json["installationId"], "10000000-0000-4000-8000-000000000001")
        XCTAssertEqual(json["deviceToken"], Self.token(byte: 1))
        XCTAssertEqual(Set(json.keys), Set(["deviceType", "installationId", "deviceToken"]))
        XCTAssertTrue(result.created)
        XCTAssertEqual(result.device.deviceType, .mobile)
    }

    func testAuthorizePairingKeepsGrantInRequestAndParsesReservedSlot() async throws {
        MIM260DeviceURLProtocol.respond(
            statusCode: 201,
            body: #"{"pairingSession":{"id":"30000000-0000-4000-8000-000000000001","expiresAt":"2026-09-04T00:10:00Z","macSlot":"reserved"},"created":true}"#
        )
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = LiveManagedConnectionDeviceAPIClient(session: session)
        let grant = Self.token(byte: 2)

        let result = try await client.authorizePairing(
            deviceToken: Self.token(byte: 3),
            requestID: "30000000-0000-4000-8000-000000000002",
            macInstallationID: "20000000-0000-4000-8000-000000000001",
            mobileTailcatPublicKey: "nodekey:mobile",
            macTailcatPublicKey: "nodekey:mac",
            managedPairingGrant: grant
        )

        let body = try XCTUnwrap(MIM260DeviceURLProtocol.capturedBody())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json["requestId"], "30000000-0000-4000-8000-000000000002")
        XCTAssertEqual(json["macInstallationId"], "20000000-0000-4000-8000-000000000001")
        XCTAssertEqual(json["mobileTailcatPublicKey"], "nodekey:mobile")
        XCTAssertEqual(json["macTailcatPublicKey"], "nodekey:mac")
        XCTAssertEqual(json["managedPairingGrant"], grant)
        XCTAssertEqual(result.macSlot, .reserved)
    }

    func testDeviceLimitErrorPreservesTypeAndLimit() async throws {
        MIM260DeviceURLProtocol.respond(
            statusCode: 409,
            body: #"{"code":"device_limit_reached","deviceType":"mac","limit":3}"#
        )
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = LiveManagedConnectionDeviceAPIClient(session: session)

        do {
            _ = try await client.registerMobileDevice(
                entitlementToken: "entitlement-token-that-is-long-enough",
                installationID: "10000000-0000-4000-8000-000000000001",
                deviceToken: Self.token(byte: 1)
            )
            XCTFail("quota rejection must be surfaced")
        } catch {
            XCTAssertEqual(
                error as? ManagedConnectionDeviceAPIError,
                .rejected(code: "device_limit_reached", deviceType: .mac, limit: 3)
            )
        }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MIM260DeviceURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func token(byte: UInt8) -> String {
        Data(repeating: byte, count: 32).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class MIM260DeviceURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var statusCode = 500
    private static var responseBody = Data()
    private static var lastRequest: URLRequest?
    private static var lastBody: Data?

    static func respond(statusCode: Int, body: String) {
        lock.lock()
        self.statusCode = statusCode
        responseBody = Data(body.utf8)
        lastRequest = nil
        lastBody = nil
        lock.unlock()
    }

    static func capturedRequest() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return lastRequest
    }

    static func capturedBody() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return lastBody
    }

    static func reset() {
        lock.lock()
        statusCode = 500
        responseBody = Data()
        lastRequest = nil
        lastBody = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var requestBody = request.httpBody
        if requestBody == nil, let stream = request.httpBodyStream {
            requestBody = Self.readAll(from: stream)
        }

        Self.lock.lock()
        Self.lastRequest = request
        Self.lastBody = requestBody
        let statusCode = Self.statusCode
        let responseBody = Self.responseBody
        Self.lock.unlock()

        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readAll(from stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4 * 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
