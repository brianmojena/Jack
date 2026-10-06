import Foundation
import Darwin

/// A single-use line-oriented child process. Both output pipes are drained from
/// background queues so structured stdout cannot deadlock behind stderr.
final class StructuredChild: @unchecked Sendable {
    let lines: AsyncThrowingStream<Data, Error>
    private let process: Process
    private let input: Pipe
    private let output: Pipe
    private let errors: Pipe
    private let lock = NSLock()
    private var stopped = false
    private var stderr = Data()

    init(executable: String, arguments: [String], directory: String, environment: [String: String] = [:]) throws {
        process = Process(); input = Pipe(); output = Pipe(); errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        process.environment = ExecutableResolver.childEnvironment().merging(environment) { _, new in new }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        lines = AsyncThrowingStream { continuation = $0 }
        do { try process.run() }
        catch { continuation.finish(throwing: error); throw error }
        let out = output.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.readLines(out, continuation: continuation) }
        let err = errors.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.drainErrors(err) }
    }

    func writeJSON(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys]) + Data([0x0A])
        lock.lock(); defer { lock.unlock() }
        guard !stopped, process.isRunning else { throw ChatProcessError.closed }
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func terminate() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        lock.unlock()
    }

    func waitForExit() async {
        let pid = process.processIdentifier
        for _ in 0..<40 {
            if !process.isRunning { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning { _ = kill(pid, SIGKILL) }
        await Task.detached(priority: .utility) { [process] in if process.isRunning { process.waitUntilExit() } }.value
    }

    func failureDescription(default fallback: String) async -> String {
        await waitForExit()
        let detail = lock.withLock { String(data: stderr.suffix(64 * 1024), encoding: .utf8) ?? "" }
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return String(trimmed.suffix(64 * 1024)) }
        if process.terminationStatus != 0 { return "\(fallback) (exit \(process.terminationStatus))." }
        return fallback
    }

    private func readLines(_ handle: FileHandle, continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        var buffer = Data()
        do {
            while true {
                let chunk = try readAvailable(handle, limit: 16 * 1024)
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    if line.count > 16 * 1024 * 1024 { throw ChatProcessError.lineTooLarge }
                    continuation.yield(line)
                }
                if buffer.count > 16 * 1024 * 1024 { throw ChatProcessError.lineTooLarge }
            }
            if !buffer.isEmpty { continuation.yield(buffer) }
            continuation.finish()
        } catch { continuation.finish(throwing: error) }
    }

    private func drainErrors(_ handle: FileHandle) {
        while true {
            guard let data = try? readAvailable(handle, limit: 4096), !data.isEmpty else { break }
            lock.withLock {
                stderr.append(data)
                if stderr.count > 64 * 1024 { stderr.removeFirst(stderr.count - 64 * 1024) }
            }
        }
    }
    private func readAvailable(_ handle: FileHandle, limit: Int) throws -> Data {
        var data = Data(count: limit)
        let count = data.withUnsafeMutableBytes { bytes in Darwin.read(handle.fileDescriptor, bytes.baseAddress!, limit) }
        if count < 0 {
            if errno == EINTR { return try readAvailable(handle, limit: limit) }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        data.count = count
        return data
    }
}

enum ChatProcessError: Error { case closed, lineTooLarge }

/// Exactly one sequential consumer spans handshake and turn parsing.
final class StructuredLineReader {
    private var iterator: AsyncThrowingStream<Data, Error>.Iterator

    init(_ stream: AsyncThrowingStream<Data, Error>) { iterator = stream.makeAsyncIterator() }

    func next() async throws -> Data? { try await iterator.next() }
}
