@preconcurrency import Foundation

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

    func run(
        executable: URL,
        arguments: [String],
        timeout: Duration = .seconds(15),
        outputLimit: Int = 1_048_576,
        environment: [String: String]? = nil
    ) async throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ProcessExecutorError.launchFailed(error.localizedDescription)
        }

        async let stdoutRead = Self.readBounded(stdoutPipe.fileHandleForReading, limit: outputLimit)
        async let stderrRead = Self.readBounded(stderrPipe.fileHandleForReading, limit: outputLimit)

        let timeoutState = LockedFlag()
        let timeoutTask = Task.detached {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, process.isRunning else { return }
            timeoutState.set()
            process.terminate()
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
