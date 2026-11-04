// Licensed under GPL-3.0. See LICENSE.
//
//  CBOR.swift
//  Nook
//
//  The CBOR subset CTAP2 uses (RFC 8949): integers, byte and text strings, arrays, maps,
//  booleans and null. Encoding is CTAP2 canonical: shortest integer forms, definite lengths,
//  and map keys sorted by major type, then encoded length, then bytes. Decoding refuses tags,
//  floats, indefinite lengths, duplicate keys and anything that runs past the input.
//

import Foundation

public indirect enum CBOR: Hashable {
    case unsigned(UInt64)
    /// The integer `-1 - n`.
    case negative(UInt64)
    case bytes(Data)
    case text(String)
    case array([CBOR])
    case map([CBOR: CBOR])
    case bool(Bool)
    case null

    public enum Failure: Error, Equatable {
        case truncated
        case unsupported
        case invalidText
        case duplicateKey
        case tooDeep
        case trailingBytes
    }

    public static func int(_ value: Int) -> CBOR {
        value >= 0 ? .unsigned(UInt64(value)) : .negative(UInt64(-1 - value))
    }

    public var int: Int? {
        switch self {
        case .unsigned(let value): return value <= UInt64(Int.max) ? Int(value) : nil
        case .negative(let value): return value <= UInt64(Int.max) ? -1 - Int(value) : nil
        default: return nil
        }
    }

    public var bytes: Data? {
        if case .bytes(let value) = self { return value }
        return nil
    }

    public var text: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    public var array: [CBOR]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var map: [CBOR: CBOR]? {
        if case .map(let value) = self { return value }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public subscript(key: Int) -> CBOR? { map?[.int(key)] }
    public subscript(key: String) -> CBOR? { map?[.text(key)] }

    // MARK: - Encoding

    public var encoded: Data {
        var out = Data()
        encode(into: &out)
        return out
    }

    private func encode(into out: inout Data) {
        switch self {
        case .unsigned(let value): Self.head(0, value, into: &out)
        case .negative(let value): Self.head(1, value, into: &out)
        case .bytes(let value):
            Self.head(2, UInt64(value.count), into: &out)
            out.append(value)
        case .text(let value):
            let utf8 = Data(value.utf8)
            Self.head(3, UInt64(utf8.count), into: &out)
            out.append(utf8)
        case .array(let items):
            Self.head(4, UInt64(items.count), into: &out)
            items.forEach { $0.encode(into: &out) }
        case .map(let entries):
            Self.head(5, UInt64(entries.count), into: &out)
            let sorted = entries.map { (key: $0.key.encoded, value: $0.value) }.sorted { Self.canonicalOrder($0.key, $1.key) }
            for entry in sorted {
                out.append(entry.key)
                entry.value.encode(into: &out)
            }
        case .bool(let value): out.append(value ? 0xf5 : 0xf4)
        case .null: out.append(0xf6)
        }
    }

    private static func head(_ major: UInt8, _ value: UInt64, into out: inout Data) {
        let type = major << 5
        switch value {
        case 0..<24: out.append(type | UInt8(value))
        case 24...0xff: out.append(contentsOf: [type | 24, UInt8(value)])
        case 0x100...0xffff: out.append(contentsOf: [type | 25, UInt8(value >> 8), UInt8(value & 0xff)])
        case 0x1_0000...0xffff_ffff:
            out.append(type | 26)
            out.append(contentsOf: (0..<4).reversed().map { UInt8((value >> ($0 * 8)) & 0xff) })
        default:
            out.append(type | 27)
            out.append(contentsOf: (0..<8).reversed().map { UInt8((value >> ($0 * 8)) & 0xff) })
        }
    }

    /// CTAP2 canonical key order over encoded keys: major type, then length, then bytes.
    static func canonicalOrder(_ a: Data, _ b: Data) -> Bool {
        let majorA = a.first.map { $0 >> 5 } ?? 0, majorB = b.first.map { $0 >> 5 } ?? 0
        if majorA != majorB { return majorA < majorB }
        if a.count != b.count { return a.count < b.count }
        return a.lexicographicallyPrecedes(b)
    }

    // MARK: - Decoding

    public static let maxDepth = 16

    /// One item that must fill `data` exactly.
    public static func decode(_ data: Data) throws -> CBOR {
        let bytes = [UInt8](data)
        var offset = 0
        let value = try decode(bytes, at: &offset, depth: 0)
        guard offset == bytes.count else { throw Failure.trailingBytes }
        return value
    }

    /// One item starting at `offset`, which moves past it; for CBOR inside authenticator data.
    public static func decode(_ data: Data, from offset: inout Int) throws -> CBOR {
        try decode([UInt8](data), at: &offset, depth: 0)
    }

    private static func decode(_ bytes: [UInt8], at offset: inout Int, depth: Int) throws -> CBOR {
        guard depth <= maxDepth else { throw Failure.tooDeep }
        guard offset < bytes.count else { throw Failure.truncated }
        let initial = bytes[offset]
        offset += 1
        let major = initial >> 5, info = initial & 0x1f

        if major == 7 {
            switch info {
            case 20: return .bool(false)
            case 21: return .bool(true)
            case 22: return .null
            default: throw Failure.unsupported
            }
        }
        let argument = try Self.argument(info, bytes, at: &offset)
        switch major {
        case 0: return .unsigned(argument)
        case 1: return .negative(argument)
        case 2, 3:
            guard argument <= UInt64(bytes.count - offset) else { throw Failure.truncated }
            let slice = Data(bytes[offset..<offset + Int(argument)])
            offset += Int(argument)
            if major == 2 { return .bytes(slice) }
            guard let text = String(data: slice, encoding: .utf8) else { throw Failure.invalidText }
            return .text(text)
        case 4:
            // Every item takes at least one byte.
            guard argument <= UInt64(bytes.count - offset) else { throw Failure.truncated }
            var items: [CBOR] = []
            items.reserveCapacity(Int(argument))
            for _ in 0..<argument { items.append(try decode(bytes, at: &offset, depth: depth + 1)) }
            return .array(items)
        case 5:
            guard argument <= UInt64(bytes.count - offset) / 2 else { throw Failure.truncated }
            var entries: [CBOR: CBOR] = [:]
            for _ in 0..<argument {
                let key = try decode(bytes, at: &offset, depth: depth + 1)
                let value = try decode(bytes, at: &offset, depth: depth + 1)
                guard entries.updateValue(value, forKey: key) == nil else { throw Failure.duplicateKey }
            }
            return .map(entries)
        default:
            throw Failure.unsupported
        }
    }

    private static func argument(_ info: UInt8, _ bytes: [UInt8], at offset: inout Int) throws -> UInt64 {
        let width: Int
        switch info {
        case 0..<24: return UInt64(info)
        case 24: width = 1
        case 25: width = 2
        case 26: width = 4
        case 27: width = 8
        default: throw Failure.unsupported
        }
        guard bytes.count - offset >= width else { throw Failure.truncated }
        var value: UInt64 = 0
        for byte in bytes[offset..<offset + width] { value = value << 8 | UInt64(byte) }
        offset += width
        return value
    }
}
