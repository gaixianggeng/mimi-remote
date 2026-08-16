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

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message): "无法启动命令：\(message)"
        case .timedOut: "命令执行超时"
        case .outputTooLarge: "命令输出超过安全上限"
        }
    }
}

actor ProcessExecutor {
    static let shared = ProcessExecutor()

    /// 用于 launchctl setenv/unsetenv 这类很短、但可能已经提交系统状态的命令。
    /// 调用方取消后仍等待独立任务返回，确保上层能够看到真实执行结果并完成
    /// 后续写入或回滚；普通命令继续使用 `run`，保持及时取消能力。
    func runToCompletion(
        executable: URL,
        arguments: [String],
        timeout: Duration = .seconds(15),
        outputLimit: Int = 1_048_576,
        environment: [String: String]? = nil
    ) async throws -> CommandResult {
        let execution = Task.detached {
            try await self.run(
                executable: executable,
                arguments: arguments,
                timeout: timeout,
                outputLimit: outputLimit,
                environment: environment
            )
        }
        return try await execution.value
    }

    func run(
        executable: URL,
        arguments: [String],
        timeout: Duration = .seconds(15),
        outputLimit: Int = 1_048_576,
        environment: [String: String]? = nil,
        forceKillAfterTimeout: Bool = false
    ) async throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Foundation 在部分 hosted macOS runner 上会在 terminate() 返回后把
        // isRunning 提前变为 false，即使目标进程忽略了 SIGTERM。用真实退出回调
        // 记录内核已回收的事实，避免因此跳过两秒后的 SIGKILL。
        let processExited = LockedFlag()
        process.terminationHandler = { _ in
            processExited.set()
        }

        do {
            try process.run()
        } catch {
            throw ProcessExecutorError.launchFailed(error.localizedDescription)
        }
        // 启动成功后立即固定 PID。部分 hosted runner 在 terminate() 后会提前
        // 清空 Process 的运行态，届时再读取 processIdentifier 可能已不是原 PID。
        let processIdentifier = process.processIdentifier

        async let stdoutRead = Self.readBounded(stdoutPipe.fileHandleForReading, limit: outputLimit)
        async let stderrRead = Self.readBounded(stderrPipe.fileHandleForReading, limit: outputLimit)

        let timeoutState = LockedFlag()
        let timeoutTask = Task.detached {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, !processExited.value else { return }
            timeoutState.set()
            // 先给 agentd 控制命令正常退出机会；如果它卡在不可取消的系统调用，
            // 仅发送 SIGTERM 会让 waitUntilExit 永久挂住，设置页也就一直显示
            // “正在更新”。两秒后只强制回收这个短命 control CLI，不触碰共享
            // Codex daemon；后端 marker/manual plist 仍保留，可安全重试。
            _ = Darwin.kill(processIdentifier, SIGTERM)
            guard forceKillAfterTimeout else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !processExited.value else { return }
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }

        let status = await withTaskCancellationHandler {
            await Task.detached {
                process.waitUntilExit()
                return process.terminationStatus
            }.value
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
        timeoutTask.cancel()

        let stdout = try await stdoutRead
        let stderr = try await stderrRead
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

    private static func readBounded(_ handle: FileHandle, limit: Int) async throws -> BoundedRead {
        try await Task.detached {
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
            return BoundedRead(data: collected, exceededLimit: exceeded)
        }.value
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
