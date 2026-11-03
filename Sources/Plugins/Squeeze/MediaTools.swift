import Foundation

/// A tool the plugin runs is not installed (or its path is wrong).
public struct ToolMissing: Error, LocalizedError, Equatable {
    public let tool: String

    public var errorDescription: String? {
        "\(tool) was not found. Install it (brew install \(tool == "cwebp" ? "webp" : tool)) or set its path in the Media compression settings."
    }
}

/// A tool ran and failed; the message is the end of its error output.
public struct ToolFailed: Error, LocalizedError, Equatable {
    public let tool: String
    public let message: String

    public var errorDescription: String? { "\(tool) failed: \(message)" }
}

/// Where the external tools are, and how to run one off the calling thread.
public struct MediaTools: Sendable, Equatable {
    public var ffmpeg: String
    public var cwebp: String

    public init(ffmpeg: String = "", cwebp: String = "") {
        self.ffmpeg = ffmpeg
        self.cwebp = cwebp
    }

    /// `ffprobe` is installed next to `ffmpeg`.
    public var ffprobe: String {
        guard !ffmpeg.isEmpty else { return "" }
        let sibling = (ffmpeg as NSString).deletingLastPathComponent + "/ffprobe"
        return FileManager.default.isExecutableFile(atPath: sibling) ? sibling : ""
    }

    var hasFFmpeg: Bool { FileManager.default.isExecutableFile(atPath: ffmpeg) }
    var hasCwebp: Bool { FileManager.default.isExecutableFile(atPath: cwebp) }

    /// Runs `executable` with `arguments` to the end, off the calling thread, and returns its standard output. Throws
    /// `ToolFailed` with the last lines of its error output when it exits with a failure, or when it is still running
    /// after `timeout` seconds: it is stopped then, so a hung tool cannot hold the compressor's lane.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30 * 60) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let output = Pipe()
                let errors = Pipe()
                process.standardOutput = output
                process.standardError = errors
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ToolMissing(tool: (executable as NSString).lastPathComponent))
                    return
                }
                // Both pipes are drained while the tool runs, so a chatty one never fills a buffer and stalls.
                let errorBox = Box()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    guard process.isRunning else { return }
                    errorBox.timedOut = true
                    process.terminate()
                }
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    errorBox.data = errors.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                if errorBox.timedOut {
                    continuation.resume(throwing: ToolFailed(
                        tool: (executable as NSString).lastPathComponent, message: "stopped after \(Int(timeout / 60)) minutes"
                    ))
                } else if process.terminationStatus == 0 {
                    continuation.resume(returning: data)
                } else {
                    let text = String(decoding: errorBox.data, as: UTF8.self)
                    let tail = text.split(separator: "\n").suffix(3).joined(separator: " ")
                    continuation.resume(throwing: ToolFailed(
                        tool: (executable as NSString).lastPathComponent, message: tail.isEmpty ? "exit \(process.terminationStatus)" : tail
                    ))
                }
            }
        }
    }

    private final class Box: @unchecked Sendable {
        var data = Data()
        var timedOut = false
    }

    /// The format and duration `ffprobe` reports for `url`: bit rate in bits per second and duration in seconds.
    func probe(_ url: URL) async throws -> (bitRate: Double, duration: Double, height: Int) {
        let tool = ffprobe
        guard !tool.isEmpty else { throw ToolMissing(tool: "ffprobe") }
        let data = try await Self.run(tool, [
            "-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path,
        ], timeout: 60)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (0, 0, 0) }
        let format = root["format"] as? [String: Any]
        let streams = root["streams"] as? [[String: Any]] ?? []
        let height = streams.first { $0["codec_type"] as? String == "video" }?["height"] as? Int ?? 0
        return (
            Double(format?["bit_rate"] as? String ?? "") ?? 0,
            Double(format?["duration"] as? String ?? "") ?? 0,
            height
        )
    }
}
