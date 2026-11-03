import Foundation

/// git's pkt-line framing: 4 hex digits giving the length (header included), then the payload; `0000` is a flush
/// packet ending a list or a file's content.
final class PacketReader {
    enum Packet: Equatable {
        case data(Data)
        case flush
    }

    struct Malformed: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { "git sent a malformed packet: \(reason)" }
    }

    /// The next bytes of input, empty at the end.
    private let source: () -> Data
    private var buffer: [UInt8] = []
    private var position = 0

    init(source: @escaping () -> Data) {
        self.source = source
    }

    /// The next packet, nil when the input ends between two packets (git is done).
    func next() throws -> Packet? {
        guard fill(4) else {
            if position == buffer.count { return nil }
            throw Malformed(reason: "the input ends inside a length")
        }
        guard let length = Int(String(decoding: buffer[position..<position + 4], as: UTF8.self), radix: 16) else {
            throw Malformed(reason: "the length is not hexadecimal")
        }
        position += 4
        if length == 0 { return .flush }
        guard length > 4 else { throw Malformed(reason: "unexpected special packet \(length)") }
        guard fill(length - 4) else { throw Malformed(reason: "the input ends inside a packet") }
        let payload = Data(buffer[position..<position + length - 4])
        position += length - 4
        return .data(payload)
    }

    /// The text lines up to the next flush, without their line feed; nil when the input ends first.
    func lines() throws -> [String]? {
        var lines: [String] = []
        while let packet = try next() {
            switch packet {
            case .flush: return lines
            case .data(let payload):
                var line = String(decoding: payload, as: UTF8.self)
                if line.hasSuffix("\n") { line.removeLast() }
                lines.append(line)
            }
        }
        if lines.isEmpty { return nil }
        throw Malformed(reason: "the input ends inside a list")
    }

    /// The bytes of the data packets up to the next flush.
    func content() throws -> Data {
        var content = Data()
        while let packet = try next() {
            switch packet {
            case .flush: return content
            case .data(let payload): content.append(payload)
            }
        }
        throw Malformed(reason: "the input ends inside a file's content")
    }

    private func fill(_ count: Int) -> Bool {
        while buffer.count - position < count {
            let chunk = source()
            if chunk.isEmpty { return false }
            if position > 0 {
                buffer.removeFirst(position)
                position = 0
            }
            buffer.append(contentsOf: chunk)
        }
        return true
    }
}

/// Packets out, sent together by `send()` once a reply is complete.
final class PacketWriter {
    /// The largest payload of one packet.
    static let maxPayload = 65516

    private let sink: (Data) throws -> Void
    private var output = Data()

    init(sink: @escaping (Data) throws -> Void) {
        self.sink = sink
    }

    func line(_ text: String) {
        packet(Data((text + "\n").utf8))
    }

    func flushPacket() {
        output.append(contentsOf: Array("0000".utf8))
    }

    /// `data` cut into packets (none when empty), not followed by a flush.
    func content(_ data: Data) {
        var start = data.startIndex
        while start < data.endIndex {
            let end = min(start + Self.maxPayload, data.endIndex)
            packet(data[start..<end])
            start = end
        }
    }

    func send() throws {
        guard !output.isEmpty else { return }
        try sink(output)
        output.removeAll(keepingCapacity: true)
    }

    private func packet(_ payload: Data) {
        output.append(contentsOf: Array(String(format: "%04x", payload.count + 4).utf8))
        output.append(payload)
    }
}

/// git's long-running filter process (gitattributes(5), "Long Running Filter Process"), protocol version 2 with the
/// clean and smudge capabilities: git starts it once per command and sends it every file to convert.
enum FilterProcess {
    /// Answers git until it closes the input. A file that fails gets `status=error` (git then stops: the filter is
    /// required) and `log` says why; a broken exchange throws.
    static func serve(reader: PacketReader, writer: PacketWriter,
                      clean: (Data, String) throws -> Data, smudge: (Data, String) throws -> Data,
                      log: (String) -> Void) throws {
        guard let hello = try reader.lines(), hello.contains("git-filter-client"), hello.contains("version=2") else {
            throw PacketReader.Malformed(reason: "no git-filter-client version=2 greeting")
        }
        writer.line("git-filter-server")
        writer.line("version=2")
        writer.flushPacket()
        try writer.send()
        let offered = try reader.lines() ?? []
        for capability in ["clean", "smudge"] where offered.contains("capability=\(capability)") {
            writer.line("capability=\(capability)")
        }
        writer.flushPacket()
        try writer.send()

        while let header = try reader.lines() {
            var fields: [String: String] = [:]
            for line in header {
                guard let equals = line.firstIndex(of: "=") else { continue }
                fields[String(line[..<equals])] = String(line[line.index(after: equals)...])
            }
            let content = try reader.content()
            let path = fields["pathname"] ?? "?"
            do {
                let converted: Data
                switch fields["command"] {
                case "clean": converted = try clean(content, path)
                case "smudge": converted = try smudge(content, path)
                default: throw PacketReader.Malformed(reason: "unknown command \(fields["command"] ?? "none")")
                }
                writer.line("status=success")
                writer.flushPacket()
                writer.content(converted)
                writer.flushPacket()
                // An empty list: the status stays "success".
                writer.flushPacket()
            } catch {
                log("\(path): \(error.localizedDescription)")
                writer.line("status=error")
                writer.flushPacket()
            }
            try writer.send()
        }
    }
}
