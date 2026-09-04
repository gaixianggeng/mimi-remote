import Foundation
import XCTest
@testable import MimiRemote

final class ManagedConnectionEventAPIClientTests: XCTestCase {
    override func tearDown() {
        MIM261EventURLProtocol.reset()
        super.tearDown()
    }

    func testEventRequestContainsOnlyApprovedCoarseFields() async throws {
        MIM261EventURLProtocol.statusCode = 202
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = LiveManagedConnectionEventAPIClient(session: session)
        let event = ManagedConnectionEvent(
            id: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
            path: .derp,
            succeeded: true,
            durationMillis: 3_200,
            errorCategory: .network,
            regionCode: " tok ",
            appVersion: "1.2.1"
        )

        try await client.send(event, deviceToken: Self.deviceToken)

        let request = try XCTUnwrap(MIM261EventURLProtocol.capturedRequest)
        let body = try XCTUnwrap(MIM261EventURLProtocol.capturedBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(request.url?.path, "/v1/connection-events")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.deviceToken)")
        XCTAssertEqual(
            Set(json.keys),
            Set(["id", "path", "succeeded", "durationBucket", "errorCategory", "regionCode", "appVersion"])
        )
        XCTAssertEqual(json["path"] as? String, "derp")
        XCTAssertEqual(json["durationBucket"] as? String, "3s_to_8s")
        XCTAssertEqual(json["errorCategory"] as? String, "none")
        XCTAssertEqual(json["regionCode"] as? String, "TOK")
        XCTAssertNil(json["ip"])
        XCTAssertNil(json["deviceName"])
        XCTAssertNil(json["address"])
        XCTAssertNil(json["token"])
        XCTAssertNil(json["content"])
    }

    func testNonDERPEventDropsRegionAndClassifiesTimeout() throws {
        let data = try JSONEncoder().encode(
            ManagedConnectionEvent(
                path: .direct,
                succeeded: false,
                durationMillis: 10_000,
                errorCategory: ManagedConnectionEventErrorCategory(error: URLError(.timedOut)),
                regionCode: "TOK",
                appVersion: "1.2.1"
            )
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["durationBucket"] as? String, "over_10s")
        XCTAssertEqual(json["errorCategory"] as? String, "timeout")
        XCTAssertNil(json["regionCode"])
    }

    func testFailedEventWithoutSystemErrorUsesUnknownCategory() throws {
        let data = try JSONEncoder().encode(
            ManagedConnectionEvent(
                path: .unknown,
                succeeded: false,
                durationMillis: 500,
                errorCategory: .none,
                regionCode: nil,
                appVersion: "1.2.1"
            )
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["errorCategory"] as? String, "unknown")
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MIM261EventURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static let deviceToken = Data(repeating: 7, count: 32).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private final class MIM261EventURLProtocol: URLProtocol {
    private static let lock = NSLock()
    static var statusCode = 500
    private(set) static var capturedRequest: URLRequest?
    private(set) static var capturedBody: Data?

    static func reset() {
        lock.lock()
        statusCode = 500
        capturedRequest = nil
        capturedBody = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            body = Self.readAll(from: stream)
        }
        Self.lock.lock()
        Self.capturedRequest = request
        Self.capturedBody = body
        let statusCode = Self.statusCode
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
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readAll(from stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4 * 1_024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
