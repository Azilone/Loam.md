import Foundation

/// A program the assistant talks to over its standard streams, one JSON message per line: lines written to its
/// stdin, its stdout read continuously (an unread pipe would block it) and split on `\n` only. Its stderr is kept, the
/// last part of it, to explain a failure.
final class ProcessLink: @unchecked Sendable {
    let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = StateLock()
    private var buffer = Data()
    private var errorTail = Data()
    private var stopped = false

    init(executable: URL, arguments: [String], folder: URL, environment: [String: String]) {
        (lines, continuation) = AsyncStream.makeStream(of: String.self)
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    var isRunning: Bool { process.isRunning }

    /// What the program printed on stderr, its last 4 KB.
    var errorOutput: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: errorTail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func start() throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                self.flush(final: true)
            } else {
                self.received(data)
            }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.lock.lock()
            self.errorTail.append(data)
            if self.errorTail.count > 4096 { self.errorTail = self.errorTail.suffix(4096) }
            self.lock.unlock()
        }
        try process.run()
    }

    /// Writes one line (a newline is added).
    func write(_ line: String) {
        lock.lock()
        let stopped = stopped
        lock.unlock()
        guard !stopped, process.isRunning else { return }
        let data = Data((line + "\n").utf8)
        // A closed pipe raises SIGPIPE-like errors through an Objective-C exception on old systems: write through
        // the file descriptor instead, which only returns an error.
        data.withUnsafeBytes { buffer in
            var offset = 0
            let fd = input.fileHandleForWriting.fileDescriptor
            while offset < buffer.count {
                let written = Foundation.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    func writeJSON(_ object: [String: Any]) {
        write(JSONLine.encode(object))
    }

    /// Asks the program to stop (SIGINT), then kills it after `grace` seconds.
    func stop(grace: TimeInterval = 3) {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        try? input.fileHandleForWriting.close()
        guard process.isRunning else { return }
        process.interrupt()
        let process = process
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            if process.isRunning { process.terminate() }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func received(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var found: [String] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { found.append(text) }
        }
        lock.unlock()
        for line in found { continuation.yield(line) }
    }

    private func flush(final: Bool) {
        lock.lock()
        let rest = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        buffer.removeAll()
        lock.unlock()
        if !rest.isEmpty { continuation.yield(rest) }
        if final { continuation.finish() }
    }
}

/// JSON lines as dictionaries: every agent speaks a different dialect, read field by field.
enum JSONLine {
    static func decode(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }
    func object(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func objects(_ key: String) -> [[String: Any]] { self[key] as? [[String: Any]] ?? [] }
}
