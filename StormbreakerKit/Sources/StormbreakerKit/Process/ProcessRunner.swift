import Foundation

/// A handle to a running child process. `@unchecked Sendable` because it wraps a
/// Foundation `Process` (a reference type) that we only read state from and
/// signal; the OS serializes the actual process operations.
public final class RunningProcess: @unchecked Sendable {
    private let process: Process

    init(process: Process) { self.process = process }

    public var pid: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }

    /// SIGTERM, then SIGKILL after a grace period if still alive. The dev server
    /// is launched via storm-run.sh, which traps SIGTERM and forwards it to the
    /// node subtree.
    public func terminate(graceSeconds: Double = 3) async {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(graceSeconds)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}

/// Spawns child processes and streams their stdout/stderr as `ServerEvent`s.
/// Stateless and `Sendable`.
public struct ProcessRunner: Sendable {
    public init() {}

    /// Launch `executableURL args…` in `workingDirectory`. Returns a live event
    /// stream (line-buffered log events + a final `.exited`) and a handle.
    /// Throws if the process fails to launch.
    public func run(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]
    ) throws -> (events: AsyncStream<ServerEvent>, process: RunningProcess) {
        let (events, continuation) = AsyncStream.makeStream(of: ServerEvent.self)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Capture the exit code via a one-shot stream so we can emit `.exited`
        // AFTER the pumps drain — never lost to a finish() race.
        let (exitStream, exitContinuation) = AsyncStream.makeStream(of: Int32.self)
        process.terminationHandler = { proc in
            exitContinuation.yield(proc.terminationStatus)
            exitContinuation.finish()
        }

        do {
            try process.run()
        } catch {
            // Launch failed: the pumps haven't been started yet, so there's nothing
            // to cancel — just finish the streams so no awaiter leaks.
            exitContinuation.finish()
            continuation.finish()
            throw error
        }

        // Start the pumps only AFTER a successful launch (kernel pipe buffers hold
        // any first bytes until the readability handlers attach) — otherwise a
        // throw would leave their detached tasks + pipe handlers dangling forever.
        let outTask = Self.pump(outPipe, stream: .stdout, into: continuation)
        let errTask = Self.pump(errPipe, stream: .stderr, into: continuation)

        // Drain order: both pumps reach EOF → await the real exit code → emit
        // `.exited` → finish. Guarantees neither a log line nor the exit code
        // is lost.
        Task.detached {
            _ = await outTask.value
            _ = await errTask.value
            var code: Int32 = -1
            for await status in exitStream { code = status }
            continuation.yield(.exited(code: code))
            continuation.finish()
        }

        return (events, RunningProcess(process: process))
    }

    /// Drains one pipe into the event stream as line-buffered `LogLine`s. The
    /// readability handler captures only a `Sendable` continuation; the mutable
    /// line buffer lives inside the consuming detached task.
    private static func pump(
        _ pipe: Pipe,
        stream: LogLine.Stream,
        into continuation: AsyncStream<ServerEvent>.Continuation
    ) -> Task<Void, Never> {
        let (dataStream, dataContinuation) = AsyncStream.makeStream(of: Data.self)
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                fileHandle.readabilityHandler = nil
                dataContinuation.finish()
            } else {
                dataContinuation.yield(data)
            }
        }
        return Task.detached {
            var buffer = Data()
            for await chunk in dataStream {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    Self.emit(lineData, stream: stream, into: continuation)
                }
            }
            if !buffer.isEmpty {
                Self.emit(buffer, stream: stream, into: continuation)
            }
        }
    }

    private static func emit(
        _ data: Data,
        stream: LogLine.Stream,
        into continuation: AsyncStream<ServerEvent>.Continuation
    ) {
        var text = ANSI.strip(String(decoding: data, as: UTF8.self))
        if text.hasSuffix("\r") { text.removeLast() }
        guard !text.isEmpty else { return }
        continuation.yield(.log(LogLine(stream: stream, text: text)))
    }
}
