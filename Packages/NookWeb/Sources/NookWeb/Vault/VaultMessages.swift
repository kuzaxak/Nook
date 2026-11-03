// Licensed under GPL-3.0. See LICENSE.
//
//  VaultMessages.swift
//  Nook
//
//  Nook ⇄ Pawl Vault bridge protocol v1: one request type per method, its reply, the error
//  envelope and the status a `hello` (or its failure) puts in Settings. Binary values are
//  base64url strings. Every params object may carry the space's profile id; v1 vaults ignore it.
//

import Foundation

/// One method of the protocol: its params are the encoded value, its result decodes as `Reply`.
public protocol VaultCall: Encodable, Sendable {
    associatedtype Reply: Decodable, Sendable
    static var method: String { get }
    /// Seconds to wait for the reply: lookups are quick, anything behind Touch ID is not.
    static var timeout: TimeInterval { get }
}

private let lookupTimeout: TimeInterval = 5
private let userPresenceTimeout: TimeInterval = 120

public struct VaultHello: VaultCall {
    public static let method = "hello"
    public static let timeout = lookupTimeout
    public let client = "Nook"
    public let version = 1
    public var profile: String?
    public init(profile: String?) { self.profile = profile }

    public struct Reply: Decodable, Sendable {
        public let vault: String
        public let version: Int
        public let paired: Bool
        public let unlocked: Bool
    }
}

public struct VaultLogin: Decodable, Equatable, Sendable {
    public let id: String
    public let username: String
    public let title: String
    public init(id: String, username: String, title: String) {
        self.id = id
        self.username = username
        self.title = title
    }
}

public struct VaultLogins: VaultCall {
    public static let method = "logins"
    public static let timeout = lookupTimeout
    public var origin: String
    public var profile: String?
    public init(origin: String, profile: String?) {
        self.origin = origin
        self.profile = profile
    }

    public struct Reply: Decodable, Sendable { public let logins: [VaultLogin] }
}

public struct VaultPassword: VaultCall {
    public static let method = "password"
    public static let timeout = userPresenceTimeout
    public var id: String
    public var origin: String
    public var profile: String?
    public init(id: String, origin: String, profile: String?) {
        self.id = id
        self.origin = origin
        self.profile = profile
    }

    public struct Reply: Decodable, Sendable {
        public let username: String
        public let password: String
    }
}

public struct VaultSave: VaultCall {
    public static let method = "save"
    public static let timeout = userPresenceTimeout
    public var origin: String
    public var username: String
    public var password: String
    public var profile: String?
    public init(origin: String, username: String, password: String, profile: String?) {
        self.origin = origin
        self.username = username
        self.password = password
        self.profile = profile
    }

    public struct Reply: Decodable, Sendable {
        public let saved: Bool
        public let id: String
    }
}

public struct VaultPasskey: Decodable, Equatable, Sendable {
    public let credentialId: String
    public let userName: String
    public let title: String
    public init(credentialId: String, userName: String, title: String) {
        self.credentialId = credentialId
        self.userName = userName
        self.title = title
    }
}

public struct VaultPasskeys: VaultCall {
    public static let method = "passkeys"
    public static let timeout = lookupTimeout
    public var rpId: String
    /// Empty means any passkey for `rpId`.
    public var allowCredentials: [String]
    public var profile: String?
    public init(rpId: String, allowCredentials: [String], profile: String?) {
        self.rpId = rpId
        self.allowCredentials = allowCredentials
        self.profile = profile
    }

    public struct Reply: Decodable, Sendable { public let passkeys: [VaultPasskey] }
}

public struct VaultAssert: VaultCall {
    public static let method = "assert"
    public static let timeout = userPresenceTimeout
    public var rpId: String
    public var credentialId: String
    public var clientDataHash: String
    /// `required`, `preferred` or `discouraged`.
    public var userVerification: String
    public var origin: String
    public var profile: String?
    public init(rpId: String, credentialId: String, clientDataHash: String, userVerification: String,
                origin: String, profile: String?) {
        self.rpId = rpId
        self.credentialId = credentialId
        self.clientDataHash = clientDataHash
        self.userVerification = userVerification
        self.origin = origin
        self.profile = profile
    }

    public struct Reply: Decodable, Sendable {
        public let credentialId: String
        public let authenticatorData: String
        public let signature: String
        public let userHandle: String?
    }
}

public struct VaultRegister: VaultCall {
    public static let method = "register"
    public static let timeout = userPresenceTimeout

    public struct User: Encodable, Sendable {
        public var id: String
        public var name: String
        public var displayName: String
        public init(id: String, name: String, displayName: String) {
            self.id = id
            self.name = name
            self.displayName = displayName
        }
    }

    public var rpId: String
    public var rpName: String
    public var user: User
    public var clientDataHash: String
    public var pubKeyCredParams: [Int]
    public var excludeCredentials: [String]
    public var origin: String
    public var profile: String?
    public init(rpId: String, rpName: String, user: User, clientDataHash: String, pubKeyCredParams: [Int],
                excludeCredentials: [String], origin: String, profile: String?) {
        self.rpId = rpId
        self.rpName = rpName
        self.user = user
        self.clientDataHash = clientDataHash
        self.pubKeyCredParams = pubKeyCredParams
        self.excludeCredentials = excludeCredentials
        self.origin = origin
        self.profile = profile
    }

    public struct Reply: Decodable, Sendable {
        public let credentialId: String
        public let attestationObject: String
        public let authenticatorData: String
        public let publicKeyAlgorithm: Int
    }
}

// MARK: - Errors

public enum VaultErrorCode: String, Decodable, Sendable {
    case unpaired, locked, denied, notFound, badRequest, `internal`

    /// A code this build does not know reads as `internal`.
    public init(from decoder: Decoder) throws {
        self = VaultErrorCode(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .internal
    }
}

public enum VaultClientError: Error, Equatable, Sendable {
    /// No socket, or nothing listening on it.
    case notRunning
    /// The process on the socket failed the code signature requirement.
    case notPawlVault
    case timeout
    /// The vault closed the connection before replying.
    case connectionClosed
    /// A reply that is not protocol v1, or a line over 1 MiB.
    case malformedResponse
    /// The vault's own `error` reply.
    case server(VaultErrorCode, String)
}

// MARK: - Codec

public enum VaultCodec {
    private struct Request<Params: Encodable>: Encodable {
        let id: Int
        let method: String
        let params: Params
    }

    private struct Header: Decodable {
        struct Failure: Decodable {
            let code: VaultErrorCode
            let message: String?
        }
        let id: Int
        let error: Failure?
    }

    private struct Success<Reply: Decodable>: Decodable {
        let result: Reply
    }

    /// The request as one JSON line, without its newline.
    public static func encode<C: VaultCall>(_ call: C, id: Int) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(Request(id: id, method: C.method, params: call))
    }

    /// The id a reply line echoes, or nil when the line is not a reply.
    public static func responseID(_ line: Data) -> Int? {
        try? JSONDecoder().decode(Header.self, from: line).id
    }

    /// The reply's result, or the vault's error as `VaultClientError.server`.
    public static func decode<C: VaultCall>(_ line: Data, for _: C.Type) throws -> C.Reply {
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: line) else { throw VaultClientError.malformedResponse }
        if let failure = header.error { throw VaultClientError.server(failure.code, failure.message ?? "") }
        guard let success = try? decoder.decode(Success<C.Reply>.self, from: line) else { throw VaultClientError.malformedResponse }
        return success.result
    }
}

// MARK: - Status

/// The status line under the Pawl Vault setting.
public enum VaultStatus: Equatable, Sendable {
    case connected
    case locked
    /// The vault accepts only Nook builds signed by its own team; this one is not.
    case notTeamSigned
    case notRunning
    case notPawlVault

    public init(_ hello: VaultHello.Reply) {
        self = !hello.paired ? .notTeamSigned : hello.unlocked ? .connected : .locked
    }

    public init(_ error: VaultClientError) {
        switch error {
        case .notPawlVault: self = .notPawlVault
        case .server(.unpaired, _): self = .notTeamSigned
        case .server(.locked, _): self = .locked
        default: self = .notRunning
        }
    }
}
