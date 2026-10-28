#if DEBUG
import SwiftUI

/// 离线 UI 回归：真实图片视图和 SessionStore，只替换 HTTP 传输，不读主机文件。
struct DebugImageRecoveryFixture: View {
    @StateObject private var store: SessionStore
    @State private var reads = 0

    init(appStore: AppStore) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageRecoveryFixtureProtocol.self]
        let client = AgentAPIClient(endpoint: "https://image-recovery.invalid", token: "fixture",
                                    session: URLSession(configuration: configuration))
        _store = StateObject(wrappedValue: SessionStore(
            appStore: appStore, conversationStore: ConversationStore(), logStore: LogStore(),
            workspaceHostClientFactory: { client }
        ))
    }

    var body: some View {
        VStack(spacing: 20) {
            ConversationImagePreview(source: .localPath(ImageRecoveryFixtureProtocol.path), title: nil,
                                     style: .make(role: .assistant, colorScheme: .light), showsCaption: false)
                .environmentObject(store)
            Text(reads, format: .number.grouping(.never))
                .accessibilityIdentifier("image.fixture.reads")
        }
        .padding()
        .task {
            while !Task.isCancelled {
                reads = ImageRecoveryFixtureProtocol.readCount
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}

private final class ImageRecoveryFixtureProtocol: URLProtocol {
    static let path = "/tmp/mimi-image-recovery-fixture.png"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var reads = 0
    static var readCount: Int { lock.withLock { reads } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, url.host == "image-recovery.invalid",
              url.path == "/api/files/read", request.httpMethod == "POST",
              request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let count = Self.lock.withLock { Self.reads += 1; return Self.reads }
        if count == 1 {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let denied = ProcessInfo.processInfo.arguments.contains("--debug-image-recovery-denied")
        let body: Data
        if denied {
            body = Data(#"{"error":"file is outside authorization scope"}"#.utf8)
        } else {
            // 合成的 20×20 PNG；不是用户图片或从本机路径读取的内容。
            let png = "iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAAAHklEQVR4nGNQKLjzn5qYYdTAUQNHDRw1cNTAkWogAJhax16XIFzAAAAAAElFTkSuQmCC"
            body = try! JSONEncoder().encode(FileReadResponse(
                path: Self.path, name: "retry-fixture.png", contentType: "image/png",
                size: Int64(Data(base64Encoded: png)!.count), contentBase64: png
            ))
        }
        let response = HTTPURLResponse(url: url, statusCode: denied ? 403 : 200,
                                       httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
#endif
