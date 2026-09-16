import XCTest
import UIKit
@testable import MimiRemote

@MainActor
final class DataURLImageDecoderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        DataURLImageDecoder.removeAllCachedImagesForTesting()
        RemoteURLImageLoader.removeAllCachedImagesForTesting()
        RemoteImageURLProtocol.reset()
    }

    func testDataURLImageDecoderDecodesValidImageAndRejectsInvalidPayloads() async throws {
        let dataURL = try makeDataURL(size: CGSize(width: 120, height: 80), color: .systemBlue)

        let image = await DataURLImageDecoder.image(from: dataURL, cacheKey: "valid", maxPixelSize: 256)
        let textPayload = await DataURLImageDecoder.image(from: "data:text/plain;base64,SGVsbG8=", cacheKey: "text", maxPixelSize: 256)
        let invalidPayload = await DataURLImageDecoder.image(from: "data:image/png;base64,not-base64", cacheKey: "invalid", maxPixelSize: 256)

        XCTAssertNotNil(image)
        XCTAssertNil(textPayload)
        XCTAssertNil(invalidPayload)
    }

    func testDataURLImageDecoderReusesCachedImageForStableKey() async throws {
        let dataURL = try makeDataURL(size: CGSize(width: 96, height: 64), color: .systemGreen)
        let firstResult = await DataURLImageDecoder.image(from: dataURL, cacheKey: "stable-digest", maxPixelSize: 256)
        let secondResult = await DataURLImageDecoder.image(from: dataURL, cacheKey: "stable-digest", maxPixelSize: 256)
        let first = try XCTUnwrap(firstResult)
        let second = try XCTUnwrap(secondResult)

        XCTAssertTrue(first === second)
    }

    func testDataURLImageDecoderDoesNotReuseSameMediaIDAcrossProfiles() async throws {
        let firstURL = try makeDataURL(size: CGSize(width: 96, height: 64), color: .systemRed)
        let secondURL = try makeDataURL(size: CGSize(width: 96, height: 64), color: .systemBlue)

        let firstResult = await DataURLImageDecoder.image(
            from: firstURL,
            cacheKey: "shared-media-id",
            profileID: "profile-a",
            maxPixelSize: 256
        )
        let secondResult = await DataURLImageDecoder.image(
            from: secondURL,
            cacheKey: "shared-media-id",
            profileID: "profile-b",
            maxPixelSize: 256
        )
        let first = try XCTUnwrap(firstResult)
        let second = try XCTUnwrap(secondResult)
        let firstAgain = DataURLImageDecoder.cachedImage(
            cacheKey: "shared-media-id",
            profileID: "profile-a",
            maxPixelSize: 256
        )
        let secondAgain = DataURLImageDecoder.cachedImage(
            cacheKey: "shared-media-id",
            profileID: "profile-b",
            maxPixelSize: 256
        )

        XCTAssertFalse(first === second)
        XCTAssertTrue(first === firstAgain)
        XCTAssertTrue(second === secondAgain)
        XCTAssertNotEqual(
            MediaRequestIdentity(profileID: "profile-a", resourceID: "shared-media-id"),
            MediaRequestIdentity(profileID: "profile-b", resourceID: "shared-media-id")
        )
    }

    func testDataURLImageDecoderDownsamplesWithoutChangingAspectRatio() async throws {
        let dataURL = try makeDataURL(size: CGSize(width: 800, height: 400), color: .systemOrange)

        let result = await DataURLImageDecoder.image(from: dataURL, cacheKey: "scaled", maxPixelSize: 100)
        let image = try XCTUnwrap(result)

        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), 100)
        XCTAssertEqual(image.size.width / image.size.height, 2, accuracy: 0.05)
    }

    func testDataURLImageDecoderHonorsTaskCancellation() async throws {
        let dataURL = try makeDataURL(size: CGSize(width: 1_024, height: 1_024), color: .systemPurple)
        let task = Task {
            await DataURLImageDecoder.image(from: dataURL, cacheKey: "cancelled", maxPixelSize: 1_024)
        }

        task.cancel()
        let result = await task.value

        XCTAssertNil(result)
    }

    func testFileImageDecoderDownsamplesPreviewAndReusesSharedCache() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 400)).image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimi-image-decoder-\(UUID().uuidString).png")
        try XCTUnwrap(image.pngData()).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let first = await DataURLImageDecoder.image(fromFileURL: url, cacheKey: "file-preview", maxPixelSize: 100)
        let second = await DataURLImageDecoder.image(fromFileURL: url, cacheKey: "file-preview", maxPixelSize: 100)
        let decoded = try XCTUnwrap(first)

        XCTAssertLessThanOrEqual(max(decoded.size.width, decoded.size.height), 100)
        XCTAssertTrue(decoded === second)
        XCTAssertTrue(decoded === DataURLImageDecoder.cachedImage(cacheKey: "file-preview", maxPixelSize: 100, fromFile: true))
        XCTAssertNil(DataURLImageDecoder.cachedImage(cacheKey: "file-preview", maxPixelSize: 100))
        XCTAssertNil(DataURLImageDecoder.cachedImage(cacheKey: "file-preview", profileID: "another-host", maxPixelSize: 100, fromFile: true))
    }

    func testFileImageDecoderScopesSamePathByProfile() async throws {
        let firstURL = try makeImageFile(color: .systemPink)
        let secondURL = try makeImageFile(color: .systemCyan)
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        let firstResult = await DataURLImageDecoder.image(
            fromFileURL: firstURL,
            cacheKey: "same/local/path.png",
            profileID: "profile-a",
            maxPixelSize: 128
        )
        let secondResult = await DataURLImageDecoder.image(
            fromFileURL: secondURL,
            cacheKey: "same/local/path.png",
            profileID: "profile-b",
            maxPixelSize: 128
        )
        let first = try XCTUnwrap(firstResult)
        let second = try XCTUnwrap(secondResult)

        XCTAssertFalse(first === second)
    }

    func testRemoteImageLoaderDownloadsDownsamplesAndReusesProfileScopedCache() async throws {
        let data = try makeImageData(size: CGSize(width: 800, height: 400), color: .systemBlue)
        RemoteImageURLProtocol.responseData = data
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteImageURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let url = try XCTUnwrap(URL(string: "https://example.com/screenshot.png"))

        let firstResult = await RemoteURLImageLoader.image(
            from: url,
            cacheKey: "remote-screenshot",
            profileID: "profile-a",
            maxPixelSize: 100,
            session: session
        )
        let first = try XCTUnwrap(firstResult)
        let cached = RemoteURLImageLoader.cachedImage(
            cacheKey: "remote-screenshot",
            profileID: "profile-a",
            maxPixelSize: 100
        )
        let otherProfile = RemoteURLImageLoader.cachedImage(
            cacheKey: "remote-screenshot",
            profileID: "profile-b",
            maxPixelSize: 100
        )

        XCTAssertLessThanOrEqual(max(first.size.width, first.size.height), 100)
        XCTAssertEqual(first.size.width / first.size.height, 2, accuracy: 0.05)
        XCTAssertTrue(first === cached)
        XCTAssertNil(otherProfile)
        XCTAssertEqual(RemoteImageURLProtocol.requestCount, 1)
    }

    func testMediaWorkerDecodesAndWritesPreviewOffMainActor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimi-media-worker-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = MediaWorker(previewRootDirectory: root)
        let payload = Data("preview-payload".utf8)
        let response = FileReadResponse(
            path: "/repo/report.pdf",
            name: "../report.pdf",
            contentType: "application/pdf",
            size: Int64(payload.count),
            contentBase64: payload.base64EncodedString()
        )

        let url = try await worker.previewURL(
            from: MediaPreviewPayload(response: response),
            profileID: "profile-a"
        )
        let ranOnMainThread = await worker.lastPreviewWorkRanOnMainThreadForTesting()

        XCTAssertFalse(ranOnMainThread)
        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertTrue(url.lastPathComponent.hasSuffix("-report.pdf"))
        XCTAssertNotEqual(url.deletingLastPathComponent(), root)
    }

    func testMediaWorkerHonorsCancellationBeforeDecode() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimi-media-worker-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = MediaWorker(previewRootDirectory: root)
        let payload = Data(repeating: 0x7f, count: 2 * 1_024 * 1_024)
        let response = FileReadResponse(
            path: "/repo/large.bin",
            name: "large.bin",
            contentType: "application/octet-stream",
            size: Int64(payload.count),
            contentBase64: payload.base64EncodedString()
        )
        let task = Task {
            try await worker.previewURL(
                from: MediaPreviewPayload(response: response),
                profileID: "profile-a"
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("取消后的媒体任务不应生成预览文件")
        } catch is CancellationError {
            // 预期路径。
        } catch {
            XCTFail("应返回 CancellationError，实际为 \(error)")
        }
        XCTAssertTrue(previewFiles(in: root).isEmpty)
    }

    func testDataURLImageDecoderRapidSourceSwitchDiscardsCancelledResult() async throws {
        let firstURL = try makeDataURL(size: CGSize(width: 1_024, height: 768), color: .systemRed)
        let secondURL = try makeDataURL(size: CGSize(width: 160, height: 90), color: .systemTeal)
        let firstTask = Task {
            await DataURLImageDecoder.image(from: firstURL, cacheKey: "source-a", maxPixelSize: 1_024)
        }
        firstTask.cancel()

        let second = await DataURLImageDecoder.image(from: secondURL, cacheKey: "source-b", maxPixelSize: 320)
        let cancelledFirst = await firstTask.value

        XCTAssertNil(cancelledFirst)
        XCTAssertNotNil(second)
    }

    private func makeDataURL(size: CGSize, color: UIColor) throws -> String {
        let data = try makeImageData(size: size, color: color)
        return "data:image/png;base64,\(data.base64EncodedString())"
    }

    private func makeImageData(size: CGSize, color: UIColor) throws -> Data {
        let image = UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return try XCTUnwrap(image.pngData())
    }

    private func makeImageFile(color: UIColor) throws -> URL {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimi-image-decoder-\(UUID().uuidString).png")
        try XCTUnwrap(image.pngData()).write(to: url, options: .atomic)
        return url
    }

    private func previewFiles(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return []
        }
        return enumerator.compactMap { element in
            guard let url = element as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else {
                return nil
            }
            return url
        }
    }
}

private final class RemoteImageURLProtocol: URLProtocol {
    private static let lock = NSLock()
    static var responseData = Data()
    private(set) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        Self.requestCount += 1
        let data = Self.responseData
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/png"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        lock.lock()
        responseData = Data()
        requestCount = 0
        lock.unlock()
    }
}
