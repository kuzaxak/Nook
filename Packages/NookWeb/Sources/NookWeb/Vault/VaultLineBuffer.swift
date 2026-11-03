// Licensed under GPL-3.0. See LICENSE.
//
//  VaultLineBuffer.swift
//  Nook
//
//  JSON-lines framing for the Pawl Vault socket: one UTF-8 JSON object per `\n`-terminated
//  line, at most 1 MiB. Reads arrive in arbitrary chunks; this turns them back into lines.
//

import Foundation

public struct VaultLineBuffer {
    public static let maxLineLength = 1 << 20

    public enum Failure: Error, Equatable {
        /// The peer sent a line over the limit; the connection must be closed.
        case lineTooLong
    }

    private var pending = Data()

    public init() {}

    /// Every line `chunk` completes, without its newline. Empty lines are dropped.
    public mutating func append(_ chunk: Data) throws -> [Data] {
        var lines: [Data] = []
        var rest = chunk[...]
        while let newline = rest.firstIndex(of: 0x0a) {
            let part = rest[rest.startIndex..<newline]
            guard pending.count + part.count <= Self.maxLineLength else { throw Failure.lineTooLong }
            let line = pending + part
            pending = Data()
            if !line.isEmpty { lines.append(line) }
            rest = rest[rest.index(after: newline)...]
        }
        guard pending.count + rest.count <= Self.maxLineLength else { throw Failure.lineTooLong }
        pending.append(contentsOf: rest)
        return lines
    }
}
