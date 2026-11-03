// Licensed under GPL-3.0. See LICENSE.
//
//  VaultFramingCheck.swift
//  Nook
//
//  JSON-lines framing on the Pawl Vault socket: lines split over reads, several lines in one
//  read, and the 1 MiB line limit:
//
//    swiftc -parse-as-library Packages/NookWeb/Sources/NookWeb/Vault/VaultLineBuffer.swift \
//           Packages/NookWeb/Checks/VaultFramingCheck.swift -o /tmp/vault-framing && /tmp/vault-framing
//

import Foundation

@main
struct VaultFramingCheck {
    static func lines(_ chunks: [String]) throws -> [String] {
        var buffer = VaultLineBuffer()
        var out: [String] = []
        for chunk in chunks {
            out += try buffer.append(Data(chunk.utf8)).map { String(decoding: $0, as: UTF8.self) }
        }
        return out
    }

    static func main() throws {
        // A line split over three reads comes out once, whole, without its newline.
        precondition(try! lines(["{\"id\":1,", "\"result\":", "{}}\n"]) == ["{\"id\":1,\"result\":{}}"])
        // Nothing until the newline arrives.
        precondition(try! lines(["{\"id\":1}"]).isEmpty)
        // Two lines and the start of a third in one read; the third completes later.
        precondition(try! lines(["{\"id\":1}\n{\"id\":2}\n{\"id\"", ":3}\n"]) == ["{\"id\":1}", "{\"id\":2}", "{\"id\":3}"])
        // A newline alone ends the pending line; empty lines carry nothing.
        precondition(try! lines(["{\"id\":4}", "\n", "\n"]) == ["{\"id\":4}"])
        // Multi-byte UTF-8 split across reads survives.
        let word = Data("{\"t\":\"é\"}\n".utf8)
        var buffer = VaultLineBuffer()
        let first = try buffer.append(word.prefix(7))
        let second = try buffer.append(word.dropFirst(7))
        precondition(first.isEmpty && second.map { String(decoding: $0, as: UTF8.self) } == ["{\"t\":\"é\"}"])

        // Exactly 1 MiB is a line; one byte more is not, whether or not the newline has come.
        let max = VaultLineBuffer.maxLineLength
        precondition(max == 1_048_576)
        var exact = VaultLineBuffer()
        precondition(try! exact.append(Data(repeating: 0x61, count: max) + Data([0x0a])).first?.count == max)

        var pending = VaultLineBuffer()
        _ = try pending.append(Data(repeating: 0x61, count: max))
        do {
            _ = try pending.append(Data([0x61]))
            preconditionFailure("oversize pending line accepted")
        } catch VaultLineBuffer.Failure.lineTooLong {}

        var whole = VaultLineBuffer()
        do {
            _ = try whole.append(Data("{}\n".utf8) + Data(repeating: 0x61, count: max + 1) + Data([0x0a]))
            preconditionFailure("oversize complete line accepted")
        } catch VaultLineBuffer.Failure.lineTooLong {}

        print("VaultFramingCheck passed")
    }
}
