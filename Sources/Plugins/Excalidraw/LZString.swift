import Foundation

/// The `compressToBase64` and `decompressFromBase64` of lz-string 1.5 (MIT), which the Obsidian Excalidraw plugin
/// uses for its ` ```compressed-json ` drawings. Works on UTF-16 code units, as JavaScript strings do, so a drawing
/// compressed in Obsidian decompresses here byte for byte.
enum LZString {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=".utf16)
    private static let values: [UInt16: Int] = Dictionary(
        uniqueKeysWithValues: alphabet.enumerated().map { ($0.element, $0.offset) }
    )

    static func compressToBase64(_ input: String) -> String {
        var output = compress(Array(input.utf16), bitsPerChar: 6) { alphabet[$0] }
        switch output.count % 4 {
        case 1: output += Array("===".utf16)
        case 2: output += Array("==".utf16)
        case 3: output += Array("=".utf16)
        default: break
        }
        return String(decoding: output, as: UTF16.self)
    }

    /// Nil when the text is not lz-string output. Whitespace (the plugin's line breaks every 256 characters) is
    /// skipped.
    static func decompressFromBase64(_ input: String) -> String? {
        let units = Array(input.utf16).filter { values[$0] != nil }
        guard !units.isEmpty else { return nil }
        guard let result = decompress(units.count, resetValue: 32, next: { values[units[$0]] ?? 0 }) else {
            return nil
        }
        return String(decoding: result, as: UTF16.self)
    }

    // MARK: - LZW on UTF-16 units

    /// Writes bits `bitsPerChar` at a time, as the JavaScript does.
    private struct BitWriter {
        let bitsPerChar: Int
        let character: (Int) -> UInt16
        var output: [UInt16] = []
        var value = 0
        var position = 0

        /// Writes the `count` low bits of `bits`, lowest first.
        mutating func write(_ bits: Int, count: Int) {
            var bits = bits
            for _ in 0..<count {
                value = (value << 1) | (bits & 1)
                bits >>= 1
                if position == bitsPerChar - 1 {
                    position = 0
                    output.append(character(value))
                    value = 0
                } else {
                    position += 1
                }
            }
        }

        mutating func flush() {
            while true {
                value <<= 1
                if position == bitsPerChar - 1 {
                    output.append(character(value))
                    return
                }
                position += 1
            }
        }
    }

    private static func compress(_ input: [UInt16], bitsPerChar: Int, character: @escaping (Int) -> UInt16) -> [UInt16] {
        // A string of the dictionary is the code of its prefix plus its last unit: one key per (code, unit).
        var singles: [UInt16: Int] = [:]
        var pairs: [Int: Int] = [:]
        var toCreate: Set<UInt16> = []
        var size = 3, numBits = 2, enlargeIn = 2
        var writer = BitWriter(bitsPerChar: bitsPerChar, character: character)
        // The current string: its code, and its unit when it is a single one.
        var w: (code: Int, single: UInt16?)?

        func grow() {
            enlargeIn -= 1
            if enlargeIn == 0 {
                enlargeIn = 1 << numBits
                numBits += 1
            }
        }

        func emit(_ w: (code: Int, single: UInt16?)) {
            if let unit = w.single, toCreate.contains(unit) {
                if unit < 256 {
                    writer.write(0, count: numBits)
                    writer.write(Int(unit), count: 8)
                } else {
                    writer.write(1, count: numBits)
                    writer.write(Int(unit), count: 16)
                }
                grow()
                toCreate.remove(unit)
            } else {
                writer.write(w.code, count: numBits)
            }
            grow()
        }

        for unit in input {
            if singles[unit] == nil {
                singles[unit] = size
                size += 1
                toCreate.insert(unit)
            }
            guard let current = w else {
                w = (singles[unit]!, unit)
                continue
            }
            let key = current.code << 16 | Int(unit)
            if let code = pairs[key] {
                w = (code, nil)
            } else {
                emit(current)
                pairs[key] = size
                size += 1
                w = (singles[unit]!, unit)
            }
        }
        if let current = w { emit(current) }
        writer.write(2, count: numBits)
        writer.flush()
        return writer.output
    }

    private static func decompress(_ length: Int, resetValue: Int, next: (Int) -> Int) -> [UInt16]? {
        var dictionary: [[UInt16]] = [[], [], []]
        var enlargeIn = 4, numBits = 3
        var value = next(0), position = resetValue, index = 1

        func read(_ count: Int) -> Int {
            var bits = 0, power = 1
            for _ in 0..<count {
                let bit = value & position
                position >>= 1
                if position == 0 {
                    position = resetValue
                    value = index < length ? next(index) : 0
                    index += 1
                }
                if bit > 0 { bits |= power }
                power <<= 1
            }
            return bits
        }

        let first: [UInt16]
        switch read(2) {
        case 0: first = [UInt16(read(8))]
        case 1: first = [UInt16(read(16))]
        default: return []
        }
        dictionary.append(first)
        var w = first
        var result = first

        while true {
            if index > length { return nil }
            var code = read(numBits)
            switch code {
            case 0, 1:
                dictionary.append([UInt16(read(code == 0 ? 8 : 16))])
                code = dictionary.count - 1
                enlargeIn -= 1
            case 2:
                return result
            default:
                break
            }
            if enlargeIn == 0 {
                enlargeIn = 1 << numBits
                numBits += 1
            }
            let entry: [UInt16]
            if code < dictionary.count {
                entry = dictionary[code]
            } else if code == dictionary.count, let head = w.first {
                entry = w + [head]
            } else {
                return nil
            }
            result += entry
            dictionary.append(w + [entry[0]])
            enlargeIn -= 1
            w = entry
            if enlargeIn == 0 {
                enlargeIn = 1 << numBits
                numBits += 1
            }
        }
    }
}
