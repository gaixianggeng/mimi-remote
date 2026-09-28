import Foundation
import Network

enum TailcatLocalEndpointProbe {
    private static let queue = DispatchQueue(
        label: "com.gaixianggeng.mimi.tailcat-local-endpoint-probe",
        qos: .utility
    )

    static func isReachable(_ endpoint: String) async -> Bool {
        guard !Task.isCancelled,
              let target = target(from: endpoint) else {
            return false
        }

        let operation = TailcatTCPProbeOperation(
            host: target.host,
            port: target.port,
            queue: queue
        )
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                operation.start(continuation)
            }
        } onCancel: {
            operation.finish(false)
        }
    }

    private static func target(from endpoint: String) -> (host: NWEndpoint.Host, port: NWEndpoint.Port)? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme != nil,
              let parsedHost = components.host?.lowercased(),
              let host = normalizedLoopbackHost(parsedHost),
              let port = components.port,
              port > 0,
              port <= Int(UInt16.max),
              let networkPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return nil
        }

        return (NWEndpoint.Host(host), networkPort)
    }

    private static func normalizedLoopbackHost(_ host: String) -> String? {
        switch host {
        case "127.0.0.1":
            return host
        case "::1", "[::1]":
            // URLComponents 在当前 Foundation 上保留 IPv6 host 的方括号，NWEndpoint 不需要它。
            return "::1"
        default:
            return nil
        }
    }
}

private final class TailcatTCPProbeOperation: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()

    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?
    private var timer: DispatchSourceTimer?

    init(host: NWEndpoint.Host, port: NWEndpoint.Port, queue: DispatchQueue) {
        connection = NWConnection(host: host, port: port, using: .tcp)
        self.queue = queue
    }

    func start(_ continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(returning: result)
            return
        }

        self.continuation = continuation
        // 回调在探测结束前强持有 operation；finish 会清空回调，主动打破生命周期环。
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.finish(true)
            case .failed, .cancelled:
                self.finish(false)
            default:
                break
            }
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1)
        timer.setEventHandler {
            self.finish(false)
        }
        self.timer = timer
        timer.resume()
        connection.start(queue: queue)
        lock.unlock()
    }

    func finish(_ result: Bool) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        let timer = timer
        self.timer = nil
        lock.unlock()

        // 仅根据本地 TCP 建连判定，不发送业务数据，也不等待远端 HTTP 结果。
        timer?.setEventHandler(handler: nil)
        timer?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation?.resume(returning: result)
    }
}
