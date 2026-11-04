// Licensed under GPL-3.0. See LICENSE.
//
//  CTAPHID.swift
//  Nook
//
//  FIDO CTAPHID framing over 64-byte HID reports (CTAP 2.1 §11.2): a message is one
//  initialization packet (channel, command with bit 7 set, 16-bit length, 57 bytes) followed by
//  continuation packets (channel, sequence 0...127, 59 bytes). The assembler takes the reports
//  of one channel and yields keepalives, errors and whole messages.
//

import Foundation

public enum CTAPHID {
    public static let reportSize = 64
    public static let broadcastChannel: UInt32 = 0xffff_ffff
    static let initData = reportSize - 7
    static let continuationData = reportSize - 5
    public static let maxPayload = initData + 128 * continuationData

    public enum Command: UInt8 {
        case ping = 0x01
        case msg = 0x03
        case lock = 0x04
        case initialize = 0x06
        case wink = 0x08
        case cbor = 0x10
        case cancel = 0x11
        case keepalive = 0x3b
        case error = 0x3f
    }

    /// KEEPALIVE status bytes.
    public enum Keepalive {
        public static let processing: UInt8 = 1
        public static let userPresenceNeeded: UInt8 = 2
    }

    /// The reports for one message, each exactly 64 bytes; nil when `payload` is too long.
    public static func packets(channel: UInt32, command: Command, payload: Data) -> [Data]? {
        guard payload.count <= maxPayload else { return nil }
        let bytes = [UInt8](payload)
        var first = channelBytes(channel) + [command.rawValue | 0x80, UInt8(bytes.count >> 8), UInt8(bytes.count & 0xff)]
        first += bytes.prefix(initData)
        var reports = [padded(first)]
        var offset = initData
        var sequence: UInt8 = 0
        while offset < bytes.count {
            let chunk = bytes[offset..<min(offset + continuationData, bytes.count)]
            reports.append(padded(channelBytes(channel) + [sequence] + chunk))
            offset += continuationData
            sequence += 1
        }
        return reports
    }

    static func channelBytes(_ channel: UInt32) -> [UInt8] {
        [UInt8(channel >> 24), UInt8((channel >> 16) & 0xff), UInt8((channel >> 8) & 0xff), UInt8(channel & 0xff)]
    }

    private static func padded(_ bytes: [UInt8]) -> Data {
        Data(bytes + [UInt8](repeating: 0, count: reportSize - bytes.count))
    }

    // MARK: - Reassembly

    public struct Assembler {
        public enum Event: Equatable {
            case keepalive(UInt8)
            case error(UInt8)
            case message(command: UInt8, payload: Data)
        }

        public enum Failure: Error, Equatable {
            case malformed
            case badSequence
        }

        public let channel: UInt32
        private var command: UInt8 = 0
        private var expected = 0
        private var buffer: [UInt8] = []
        private var nextSequence: UInt8 = 0
        private var assembling = false

        public init(channel: UInt32) {
            self.channel = channel
        }

        /// One input report. Reports for other channels, and continuations with no message
        /// under way, give nil.
        public mutating func add(_ report: Data) throws -> Event? {
            let bytes = [UInt8](report)
            guard bytes.count >= 7 else { throw Failure.malformed }
            let reportChannel = bytes[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            guard reportChannel == channel else { return nil }
            let fifth = bytes[4]

            if fifth & 0x80 != 0 {
                let command = fifth & 0x7f
                let length = Int(bytes[5]) << 8 | Int(bytes[6])
                switch command {
                case Command.keepalive.rawValue, Command.error.rawValue:
                    guard length >= 1 else { throw Failure.malformed }
                    assembling = false
                    return command == Command.keepalive.rawValue ? .keepalive(bytes[7]) : .error(bytes[7])
                default:
                    guard length <= maxPayload else { throw Failure.malformed }
                    self.command = command
                    expected = length
                    buffer = Array(bytes[7..<min(bytes.count, 7 + length)])
                    nextSequence = 0
                    assembling = true
                }
            } else {
                guard assembling else { return nil }
                guard fifth == nextSequence, fifth < 0x80 else {
                    assembling = false
                    throw Failure.badSequence
                }
                nextSequence += 1
                buffer += bytes[5..<min(bytes.count, 5 + expected - buffer.count)]
            }
            guard buffer.count >= expected else { return nil }
            assembling = false
            return .message(command: command, payload: Data(buffer))
        }
    }

    // MARK: - CTAPHID_INIT

    public struct InitResponse: Equatable {
        public let channel: UInt32
        public let protocolVersion: UInt8
        public let deviceVersion: (major: UInt8, minor: UInt8, build: UInt8)
        public let capabilities: UInt8

        public var supportsCBOR: Bool { capabilities & 0x04 != 0 }

        public static func == (a: InitResponse, b: InitResponse) -> Bool {
            a.channel == b.channel && a.protocolVersion == b.protocolVersion && a.capabilities == b.capabilities
                && a.deviceVersion == b.deviceVersion
        }

        /// The reply to an INIT that sent `nonce`; nil for another sender's reply or a bad one.
        public init?(_ payload: Data, nonce: Data) {
            let bytes = [UInt8](payload)
            guard bytes.count >= 17, Data(bytes[0..<8]) == nonce else { return nil }
            let channel = bytes[8..<12].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            guard channel != 0, channel != CTAPHID.broadcastChannel else { return nil }
            self.channel = channel
            protocolVersion = bytes[12]
            deviceVersion = (bytes[13], bytes[14], bytes[15])
            capabilities = bytes[16]
        }
    }
}
