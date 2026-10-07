@preconcurrency import Foundation
import Darwin

struct CommandResult: Equatable, Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data

    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

enum ProcessExecutorError: LocalizedError {
    case launchFailed(String)
    case timedOut
    case outputTooLarge
    case inputTooLarge

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message): "无法启动命令：\(message)"
        case .timedOut: "命令执行超时"
        case .outputTooLarge: "命令输出超过安全上限"
        case .inputTooLarge: "命令输入超过安全上限"
        }
    }
}

actor ProcessExecutor {
    static let shared = ProcessExecutor()

    func run(
        executable: URL,
        arguments: [String],
        timeout: Duration = .seconds(15),
        outputLimit: Int = 1_048_576,
        environment: [String: String]? = nil,
        forceKillAfterTimeout: Bool = false,
        standardInput: Data? = nil
    ) async throws -> CommandResult {
        guard (standardInput?.count ?? 0) <= 16_384 else {
            throw ProcessExecutorError.inputTooLarge
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // 启动链接含凭据，只经私有 stdin 传递，不能出现在 argv 或日志中。
        let inputPipe = standardInput.map { _ in Pipe() }
        if let inputPipe {
            // 子进程提前退出时只应得到 EPIPE，不能让 SIGPIPE 终止整个 Mac App。
            _ = Darwin.fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            process.standardInput = inputPipe
        }
        defer {
            try? inputPipe?.fileHandleForReading.close()
            try? inputPipe?.fileHandleForWriting.close()
        }

        do {
            try process.run()
        } catch {
            throw ProcessExecutorError.launchFailed(error.localizedDescription)
        }
        // 父进程不能保留读端，否则子进程超时退出后，阻塞的写入仍等不到 EPIPE。
        try? inputPipe?.fileHandleForReading.close()
        // hosted runner 上 Process.isRunning 可能在子进程仍存活时返回 false；
        // 启动成功后固定 PID，并以 waitUntilExit 返回后取消 timeout task 作为
        // 唯一退出门控，避免依赖 Foundation 的运行态缓存。
        let processIdentifier = process.processIdentifier

        async let stdoutRead = Self.readBounded(stdoutPipe.fileHandleForReading, limit: outputLimit)
        async let stderrRead = Self.readBounded(stderrPipe.fileHandleForReading, limit: outputLimit)

        let timeoutState = LockedFlag()
        let processFinished = LockedFlag()
        // 不能把 timeout 也放进 Swift cooperative executor：stdout、stderr 和
        // waitUntilExit 都可能同步阻塞，在小规格 CI/用户机器上会占满可用线程，
        // 让本应唤醒并回收进程的 timeout task 永远得不到调度。
        let timeoutWorkItem = DispatchWorkItem {
            guard !processFinished.value else { return }
            timeoutState.set()
            // 先给 agentd 控制命令正常退出机会；如果它卡在不可取消的系统调用，
            // 仅发送 SIGTERM 会让 waitUntilExit 永久挂住，设置页也就一直显示
            // “正在更新”。两秒后只强制回收这个短命 control CLI，不触碰
            // Desktop 或其 IPC 连接；配置文件仍保持原子写入，可安全重试。
            _ = Darwin.kill(processIdentifier, SIGTERM)
            guard forceKillAfterTimeout else { return }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                // waitUntilExit 已返回时会先标记 finished；二次检查避免误伤
                // 已退出 control command 之后复用同一 PID 的新进程。
                guard !processFinished.value else { return }
                _ = Darwin.kill(processIdentifier, SIGKILL)
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: Self.dispatchDeadline(after: timeout),
            execute: timeoutWorkItem
        )

        // 先启动读端并安装超时，再在专用线程写入；不能用管道容量假设阻塞 actor。
        async let inputWrite: Void = Self.writeInput(inputPipe?.fileHandleForWriting, data: standardInput)

        let status = await withTaskCancellationHandler {
            await Self.waitUntilExit(process)
        } onCancel: {
            _ = Darwin.kill(processIdentifier, SIGTERM)
        }
        processFinished.set()
        timeoutWorkItem.cancel()

        let stdout = try await stdoutRead
        let stderr = try await stderrRead
        await inputWrite
        if Task.isCancelled {
            throw CancellationError()
        }
        if stdout.exceededLimit || stderr.exceededLimit {
            throw ProcessExecutorError.outputTooLarge
        }
        if timeoutState.value {
            throw ProcessExecutorError.timedOut
        }
        return CommandResult(status: status, stdout: stdout.data, stderr: stderr.data)
    }

    private struct BoundedRead {
        let data: Data
        let exceededLimit: Bool
    }

    private static func writeInput(_ handle: FileHandle?, data: Data?) async {
        guard let handle, let data else { return }
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                // 不回显输入或底层错误。提前退出、超时与取消由进程结果统一报告。
                try? handle.write(contentsOf: data)
                try? handle.close()
                continuation.resume()
            }
        }
    }

    private static func dispatchDeadline(after duration: Duration) -> DispatchTime {
        let components = duration.components
        let seconds = max(
            0,
            Double(components.seconds) + Double(components.attoseconds) / 1e18
        )
        return .now() + seconds
    }

    private static func waitUntilExit(_ process: Process) async -> Int32 {
        await withCheckedContinuation { continuation in
            // Process.waitUntilExit 是同步阻塞 API。不能用 Task.detached 包装，
            // 否则会占住 Swift cooperative executor 的 worker。
            Thread.detachNewThread {
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus)
            }
        }
    }

    private static func readBounded(_ handle: FileHandle, limit: Int) async throws -> BoundedRead {
        try await withCheckedThrowingContinuation { continuation in
            // FileHandle.read(upToCount:) 同样是同步阻塞 API；每次命令最多使用
            // stdout/stderr 两条短命专用线程，避免挤占 timeout 所需的异步 worker。
            Thread.detachNewThread {
                do {
                    var collected = Data()
                    var exceeded = false
                    var total = 0
                    while true {
                        let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
                        if chunk.isEmpty { break }
                        total += chunk.count
                        if collected.count < limit {
                            let remaining = limit - collected.count
                            collected.append(chunk.prefix(remaining))
                        }
                        if total > limit {
                            exceeded = true
                        }
                    }
                    continuation.resume(
                        returning: BoundedRead(data: collected, exceededLimit: exceeded)
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set() {
        lock.lock()
        stored = true
        lock.unlock()
    }
}
