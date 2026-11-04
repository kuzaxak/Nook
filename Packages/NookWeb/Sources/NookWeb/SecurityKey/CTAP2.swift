// Licensed under GPL-3.0. See LICENSE.
//
//  CTAP2.swift
//  Nook
//
//  The CTAP 2.0/2.1 commands Nook sends to a security key and the replies it reads:
//  authenticatorGetInfo, MakeCredential, GetAssertion, GetNextAssertion, ClientPIN and
//  Selection. Parameters use the spec's integer keys; CBOR.encoded sorts them canonically.
//

import Foundation

public enum CTAP2 {
    public enum Command: UInt8 {
        case makeCredential = 0x01
        case getAssertion = 0x02
        case getInfo = 0x04
        case clientPIN = 0x06
        case getNextAssertion = 0x08
        case selection = 0x0b
    }

    public enum Status {
        public static let ok: UInt8 = 0x00
        public static let invalidCommand: UInt8 = 0x01
        public static let credentialExcluded: UInt8 = 0x19
        public static let unsupportedAlgorithm: UInt8 = 0x26
        public static let operationDenied: UInt8 = 0x27
        public static let keyStoreFull: UInt8 = 0x28
        public static let keepaliveCancel: UInt8 = 0x2d
        public static let noCredentials: UInt8 = 0x2e
        public static let userActionTimeout: UInt8 = 0x2f
        public static let pinInvalid: UInt8 = 0x31
        public static let pinBlocked: UInt8 = 0x32
        public static let pinAuthInvalid: UInt8 = 0x33
        public static let pinAuthBlocked: UInt8 = 0x34
        public static let pinNotSet: UInt8 = 0x35
        public static let pinRequired: UInt8 = 0x36
        public static let pinPolicyViolation: UInt8 = 0x37
        public static let actionTimeout: UInt8 = 0x3a
    }

    public enum ClientPIN {
        public static let getRetries: UInt8 = 0x01
        public static let getKeyAgreement: UInt8 = 0x02
        public static let getPinToken: UInt8 = 0x05
        public static let getPinUvAuthTokenUsingPinWithPermissions: UInt8 = 0x09
    }

    public struct Permissions: OptionSet {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let makeCredential = Permissions(rawValue: 0x01)
        public static let getAssertion = Permissions(rawValue: 0x02)
    }

    public struct Failure: Error, Equatable {
        public let status: UInt8
    }

    public struct Malformed: Error {}

    // MARK: - authenticatorGetInfo

    public struct Info: Equatable {
        public var versions: [String]
        public var aaguid: Data
        public var options: [String: Bool]
        public var maxMsgSize: Int
        public var pinUvAuthProtocols: [Int]
        public var maxCredentialCountInList: Int?
        public var maxCredentialIdLength: Int?
        public var minPINLength: Int

        public init(_ reply: CBOR) throws {
            guard let versions = reply[1]?.array?.compactMap(\.text), let aaguid = reply[3]?.bytes, aaguid.count == 16
            else { throw Malformed() }
            self.versions = versions
            self.aaguid = aaguid
            var options: [String: Bool] = [:]
            for (key, value) in reply[4]?.map ?? [:] {
                if let name = key.text, let flag = value.bool { options[name] = flag }
            }
            self.options = options
            maxMsgSize = reply[5]?.int ?? 1024
            pinUvAuthProtocols = reply[6]?.array?.compactMap(\.int) ?? []
            maxCredentialCountInList = reply[7]?.int.flatMap { $0 > 0 ? $0 : nil }
            maxCredentialIdLength = reply[8]?.int.flatMap { $0 > 0 ? $0 : nil }
            minPINLength = max(reply[0x0d]?.int ?? 4, 4)
        }

        public var supportsFIDO2: Bool { versions.contains { $0.hasPrefix("FIDO_2_") } }
        /// authenticatorSelection (0x0B) exists from CTAP 2.1 on, not in 2.1 previews.
        public var supportsSelection: Bool { versions.contains("FIDO_2_1") }
        /// `clientPin` is present (true once a PIN is set, false before).
        public var supportsPIN: Bool { options["clientPin"] != nil }
        public var hasPIN: Bool { options["clientPin"] == true }
        public var supportsResidentKeys: Bool { options["rk"] == true }
        public var supportsPermissions: Bool { options["pinUvAuthToken"] == true }
        /// CTAP 2.1: a non-discoverable credential needs no UV even with a PIN set.
        public var makeCredentialWithoutUV: Bool { options["makeCredUvNotRqd"] == true }
        public var alwaysUV: Bool { options["alwaysUv"] == true }
    }

    // MARK: - Requests

    public static func descriptor(_ id: Data) -> CBOR {
        .map([.text("id"): .bytes(id), .text("type"): .text("public-key")])
    }

    public struct PinUvAuth {
        public let parameter: Data
        public let protocolVersion: Int
    }

    public static func makeCredential(clientDataHash: Data, rp: (id: String, name: String),
                                      user: (id: Data, name: String, displayName: String), algorithms: [Int],
                                      excludeList: [Data], residentKey: Bool, auth: PinUvAuth?) -> CBOR {
        var rpEntity: [CBOR: CBOR] = [.text("id"): .text(rp.id)]
        if !rp.name.isEmpty { rpEntity[.text("name")] = .text(truncated(rp.name)) }
        var userEntity: [CBOR: CBOR] = [.text("id"): .bytes(user.id)]
        if !user.name.isEmpty { userEntity[.text("name")] = .text(truncated(user.name)) }
        if !user.displayName.isEmpty { userEntity[.text("displayName")] = .text(truncated(user.displayName)) }
        var parameters: [CBOR: CBOR] = [
            .int(1): .bytes(clientDataHash),
            .int(2): .map(rpEntity),
            .int(3): .map(userEntity),
            .int(4): .array(algorithms.map { .map([.text("alg"): .int($0), .text("type"): .text("public-key")]) }),
        ]
        if !excludeList.isEmpty { parameters[.int(5)] = .array(excludeList.map(descriptor)) }
        if residentKey { parameters[.int(7)] = .map([.text("rk"): .bool(true)]) }
        if let auth {
            parameters[.int(8)] = .bytes(auth.parameter)
            parameters[.int(9)] = .int(auth.protocolVersion)
        }
        return .map(parameters)
    }

    public static func getAssertion(rpId: String, clientDataHash: Data, allowList: [Data], userPresence: Bool,
                                    auth: PinUvAuth?) -> CBOR {
        var parameters: [CBOR: CBOR] = [.int(1): .text(rpId), .int(2): .bytes(clientDataHash)]
        if !allowList.isEmpty { parameters[.int(3)] = .array(allowList.map(descriptor)) }
        if !userPresence { parameters[.int(5)] = .map([.text("up"): .bool(false)]) }
        if let auth {
            parameters[.int(6)] = .bytes(auth.parameter)
            parameters[.int(7)] = .int(auth.protocolVersion)
        }
        return .map(parameters)
    }

    public static func clientPIN(_ subCommand: UInt8, protocolVersion: Int, keyAgreement: CBOR? = nil,
                                 pinHashEnc: Data? = nil, permissions: Permissions? = nil, rpId: String? = nil) -> CBOR {
        var parameters: [CBOR: CBOR] = [.int(1): .int(protocolVersion), .int(2): .int(Int(subCommand))]
        if let keyAgreement { parameters[.int(3)] = keyAgreement }
        if let pinHashEnc { parameters[.int(6)] = .bytes(pinHashEnc) }
        if let permissions { parameters[.int(9)] = .int(permissions.rawValue) }
        if let rpId { parameters[.int(0x0a)] = .text(rpId) }
        return .map(parameters)
    }

    /// At most 64 bytes, cut at a character boundary, as CTAP 2.1 lets platforms do.
    static func truncated(_ text: String) -> String {
        var out = ""
        var size = 0
        for character in text {
            let length = character.utf8.count
            guard size + length <= 64 else { break }
            out.append(character)
            size += length
        }
        return out
    }

    // MARK: - Replies

    public struct Attestation {
        public let format: String
        public let authenticatorData: Data

        public init(_ reply: CBOR) throws {
            guard let format = reply[1]?.text, let authenticatorData = reply[2]?.bytes, reply[3]?.map != nil
            else { throw Malformed() }
            self.format = format
            self.authenticatorData = authenticatorData
        }
    }

    public struct Assertion {
        public let credentialID: Data?
        public let authenticatorData: Data
        public let signature: Data
        public let userID: Data?
        public let userName: String?
        public let userDisplayName: String?
        public let numberOfCredentials: Int?

        public init(_ reply: CBOR) throws {
            guard let authenticatorData = reply[2]?.bytes, let signature = reply[3]?.bytes else { throw Malformed() }
            if let credential = reply[1] {
                guard let id = credential["id"]?.bytes else { throw Malformed() }
                credentialID = id
            } else {
                credentialID = nil
            }
            self.authenticatorData = authenticatorData
            self.signature = signature
            if let user = reply[4] {
                guard let id = user["id"]?.bytes else { throw Malformed() }
                userID = id
                userName = user["name"]?.text
                userDisplayName = user["displayName"]?.text
            } else {
                userID = nil
                userName = nil
                userDisplayName = nil
            }
            numberOfCredentials = reply[5]?.int
        }
    }
}
