import Foundation

/// One line of the debug channel, client to app: a JSON object with a `cmd` and that command's parameters next to it,
/// and an optional `id` the answer repeats.
///
///     {"id": 1, "cmd": "click", "x": 300, "y": 200}
public struct DebugRequest: Hashable, Sendable, Codable {
    public var id: DebugValue?
    public var cmd: String
    public var params: [String: DebugValue]

    public init(cmd: String, params: [String: DebugValue] = [:], id: DebugValue? = nil) {
        self.cmd = cmd
        self.params = params
        self.id = id
    }

    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        guard let cmdKey = Key(stringValue: "cmd") else { throw DebugError.malformed("no cmd") }
        guard let cmd = try container.decodeIfPresent(String.self, forKey: cmdKey) else {
            throw DebugError.malformed("A request needs a \"cmd\".")
        }
        self.cmd = cmd
        var params: [String: DebugValue] = [:]
        var id: DebugValue?
        for key in container.allKeys where key.stringValue != "cmd" {
            let value = try container.decode(DebugValue.self, forKey: key)
            if key.stringValue == "id" { id = value } else { params[key.stringValue] = value }
        }
        self.id = id
        self.params = params
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(cmd, forKey: Key(stringValue: "cmd")!)
        if let id { try container.encode(id, forKey: Key(stringValue: "id")!) }
        for (name, value) in params { try container.encode(value, forKey: Key(stringValue: name)!) }
    }

    public subscript(name: String) -> DebugValue? { params[name] }
}

/// One line of the debug channel, app to client.
///
///     {"id": 1, "ok": true, "result": {"path": "/tmp/a.png"}}
///     {"id": 1, "ok": false, "error": "No element with id \"x\"."}
public struct DebugResponse: Hashable, Sendable, Codable {
    public var id: DebugValue?
    public var ok: Bool
    public var result: DebugValue?
    public var error: String?

    public init(id: DebugValue? = nil, ok: Bool, result: DebugValue? = nil, error: String? = nil) {
        self.id = id
        self.ok = ok
        self.result = result
        self.error = error
    }

    public static func success(_ result: DebugValue? = nil, id: DebugValue? = nil) -> DebugResponse {
        DebugResponse(id: id, ok: true, result: result)
    }

    public static func failure(_ message: String, id: DebugValue? = nil) -> DebugResponse {
        DebugResponse(id: id, ok: false, error: message)
    }
}

public enum DebugError: Error, Equatable, CustomStringConvertible {
    case malformed(String)
    case missing(String)
    case unknownCommand(String)
    case failed(String)

    public var description: String {
        switch self {
        case .malformed(let message), .failed(let message): message
        case .missing(let name): "Missing or invalid parameter \"\(name)\"."
        case .unknownCommand(let name): "Unknown command \"\(name)\". Try \"help\"."
        }
    }
}

/// How the one JSON line of a message is written and read.
public enum DebugCoding {
    public static func decodeRequest(_ line: Data) throws -> DebugRequest {
        do {
            return try JSONDecoder().decode(DebugRequest.self, from: line)
        } catch let error as DebugError {
            throw error
        } catch {
            throw DebugError.malformed("Not a JSON object: \(line.prefix(80).map { String(UnicodeScalar($0)) }.joined())")
        }
    }

    public static func encode<T: Encodable>(_ message: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(message)) ?? Data("{\"ok\":false,\"error\":\"encoding failed\"}".utf8)
    }
}
