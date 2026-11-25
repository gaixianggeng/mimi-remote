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
        standardInput: Data? = nil,
        onStderrLine: (@Sendable (String) -> Void)? = nil
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

        let wakePipe: WakePipe
        do {
            wakePipe = try WakePipe()
        } catch {
            throw ProcessExecutorError.launchFailed(error.localizedDescription)
        }
        defer {
            wakePipe.closeAll()
        }

        do {
            try process.run()
        } catch {
            throw ProcessExecutorError.launchFailed(error.localizedDescription)
        }
        // 父进程不能保留读端，否则子进程超时退出后，阻塞的写入仍等不到 EPIPE。
        try? inputPipe?.fileHandleForReading.close()
        // hosted runner 上 Process.isRunning 可能在子进程仍存活时返回 false；
        // 启动成功后固定 PID，并以 waitUntilExit 与管道排空全部完成后取消
        // timeout task 作为唯一退出门控，避免依赖 Foundation 的运行态缓存，也防止
        // 继承了写端句柄的后代进程在主子进程退出后令排空无限期挂住。
        let processIdentifier = process.processIdentifier

        let timeoutState = LockedFlag()
        let processFinished = LockedFlag()
        let allDone = LockedFlag()
        @Sendable func stopCommand() {
            if !processFinished.value {
                // 先给 agentd 控制命令正常退出机会；如果它卡在不可取消的系统调用，
                // 仅发送 SIGTERM 会让 waitUntilExit 永久挂住，设置页也就一直显示
                // “正在更新”。两秒后只强制回收这个短命 control CLI，不触碰
                // Desktop 或其 IPC 连接；配置文件仍保持原子写入，可安全重试。
                _ = Darwin.kill(processIdentifier, SIGTERM)
                if forceKillAfterTimeout {
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                        // waitUntilExit 已返回时会先标记 finished；二次检查避免误伤
                        // 已退出 control command 之后复用同一 PID 的新进程。
                        guard !processFinished.value else { return }
                        _ = Darwin.kill(processIdentifier, SIGKILL)
                    }
                }
            }
            // 无论主子进程是否已退出，到期立即唤醒管道读线程，避免后代进程持有写端导致无限等待。
            wakePipe.trigger()
        }
        // Run the deadline independently of the workers draining the child process.
        let timeoutWorkItem = DispatchWorkItem {
            guard !allDone.value else { return }
            timeoutState.set()
            stopCommand()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: Self.dispatchDeadline(after: timeout),
            execute: timeoutWorkItem
        )
        defer {
            allDone.set()
            timeoutWorkItem.cancel()
        }

        let (status, stdout, stderr) = try await withTaskCancellationHandler {
            async let stdoutRead = Self.readBounded(
                stdoutPipe.fileHandleForReading,
                wakeFD: wakePipe.readFD,
                limit: outputLimit
            )
            async let stderrRead = Self.readBounded(
                stderrPipe.fileHandleForReading,
                wakeFD: wakePipe.readFD,
                limit: outputLimit,
                onLine: onStderrLine
            )
            // 先启动读端并安装超时，再在专用线程写入；不能用管道容量假设阻塞 actor。
            async let inputWrite: Void = Self.writeInput(inputPipe?.fileHandleForWriting, data: standardInput)

            let exitStatus = await Self.waitUntilExit(process)
            processFinished.set()

            let stdoutResult = try await stdoutRead
            let stderrResult = try await stderrRead
            await inputWrite
            allDone.set()
            timeoutWorkItem.cancel()
            return (exitStatus, stdoutResult, stderrResult)
        } onCancel: {
            stopCommand()
        }

        if Task.isCancelled {
            throw CancellationError()
        }
        if timeoutState.value {
            throw ProcessExecutorError.timedOut
        }
        if stdout.exceededLimit || stderr.exceededLimit {
            throw ProcessExecutorError.outputTooLarge
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

    private static func readBounded(
        _ handle: FileHandle,
        wakeFD: Int32,
        limit: Int,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> BoundedRead {
        try await withCheckedThrowingContinuation { continuation in
            // 每次命令最多使用 stdout/stderr 两条短命专用线程，通过 poll(2) 同时等待管道与
            // deadline/cancel 唤醒句柄，既能让流式进度逐行即时送达，也能在超时或取消时立刻结束排空。
            Thread.detachNewThread {
                do {
                    var collected = Data()
                    var lineBuffer = Data()
                    var exceeded = false
                    var total = 0
                    let fd = handle.fileDescriptor
                    var rawBuffer = [UInt8](repeating: 0, count: 64 * 1024)
                    try withExtendedLifetime(handle) {
                        while true {
                            var pfds: [pollfd] = [
                                pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                                pollfd(fd: wakeFD, events: Int16(POLLIN), revents: 0),
                            ]
                            var ready: Int32
                            repeat {
                                ready = Darwin.poll(&pfds, nfds_t(pfds.count), -1)
                            } while ready < 0 && errno == EINTR
                            if ready < 0 {
                                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                            }
                            if (pfds[1].revents & Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL)) != 0 {
                                // deadline 到期或任务已取消，立即停止管道排空。
                                lineBuffer.removeAll()
                                break
                            }
                            if (pfds[0].revents & Int16(POLLIN)) != 0 {
                                var n: Int
                                repeat {
                                    n = Darwin.read(fd, &rawBuffer, rawBuffer.count)
                                } while n < 0 && errno == EINTR
                                if n < 0 {
                                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                                }
                                if n == 0 { break }
                                let chunk = Data(rawBuffer[0..<n])
                                total += chunk.count
                                if collected.count < limit {
                                    let remaining = limit - collected.count
                                    collected.append(chunk.prefix(remaining))
                                }
                                if total > limit {
                                    exceeded = true
                                }
                                if let onLine, !exceeded {
                                    lineBuffer.append(chunk)
                                    while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
                                        var rawLine = lineBuffer[..<newlineIndex]
                                        if rawLine.last == 0x0D {
                                            rawLine = rawLine.dropLast()
                                        }
                                        onLine(String(decoding: rawLine, as: UTF8.self))
                                        lineBuffer.removeSubrange(...newlineIndex)
                                    }
                                }
                            } else if (pfds[0].revents & Int16(POLLHUP | POLLERR | POLLNVAL)) != 0 {
                                break
                            }
                        }
                    }
                    if let onLine, !exceeded, !lineBuffer.isEmpty {
                        var rawLine = lineBuffer[...]
                        if rawLine.last == 0x0D {
                            rawLine = rawLine.dropLast()
                        }
                        onLine(String(decoding: rawLine, as: UTF8.self))
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

private final class WakePipe: @unchecked Sendable {
    private let lock = NSLock()
    let readFD: Int32
    private var writeFD: Int32
    private var readClosed = false

    init() throws {
        var fds: [Int32] = [-1, -1]
        guard Darwin.pipe(&fds) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        _ = Darwin.fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        _ = Darwin.fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        readFD = fds[0]
        writeFD = fds[1]
    }

    func trigger() {
        lock.lock()
        let fd = writeFD
        writeFD = -1
        lock.unlock()
        if fd >= 0 {
            _ = Darwin.close(fd)
        }
    }

    func closeAll() {
        trigger()
        lock.lock()
        let shouldCloseRead = !readClosed
        readClosed = true
        lock.unlock()
        if shouldCloseRead, readFD >= 0 {
            _ = Darwin.close(readFD)
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
