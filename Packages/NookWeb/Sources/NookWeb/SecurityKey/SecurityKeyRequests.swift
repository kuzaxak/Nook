// Licensed under GPL-3.0. See LICENSE.
//
//  SecurityKeyRequests.swift
//  Nook
//
//  The boundary between the passkey shim and a security key ceremony. A request is built from
//  the shim's message and the frame's origin as WebKit reports it: HTTPS, or HTTP on localhost;
//  never an IP address; an rpId the origin may claim; clientDataJSON written by Nook. A reply
//  is the dictionary the shim turns into a PublicKeyCredential.
//

import Foundation

public enum SecurityKeyRequirement: String {
    case required, preferred, discouraged
}

public struct SecurityKeyCreateRequest {
    public let rpId: String
    public let rpName: String
    public let userID: Data
    public let userName: String
    public let userDisplayName: String
    public let clientDataJSON: Data
    public let algorithms: [Int]
    public let excludeList: [Data]
    public let residentKey: SecurityKeyRequirement
    public let userVerification: SecurityKeyRequirement
    public let credProps: Bool
    public let timeout: Duration

    public var clientDataHash: Data { WebAuthnClientData.hash(clientDataJSON) }
}

public struct SecurityKeyGetRequest {
    public let rpId: String
    public let clientDataJSON: Data
    public let allowList: [Data]
    public let userVerification: SecurityKeyRequirement
    public let timeout: Duration

    public var clientDataHash: Data { WebAuthnClientData.hash(clientDataJSON) }
}

public struct SecurityKeyCreated: Equatable {
    public let credentialID: Data
    public let authenticatorData: Data
    public let attestationObject: Data
    public let publicKeyAlgorithm: Int
    public let publicKey: Data?
    public let residentKey: Bool
}

public struct SecurityKeyAsserted: Equatable {
    public let credentialID: Data
    public let authenticatorData: Data
    public let signature: Data
    public let userHandle: Data?
}

public enum SecurityKeyOptions {
    public static let defaultTimeout: Duration = .seconds(300)
    public static let timeoutRange: ClosedRange<Duration> = .seconds(15) ... .seconds(600)

    /// The frame's origin and host when a security key may serve it.
    public static func origin(scheme: String, host: String, port: Int) -> Result<(origin: String, host: String), WebAuthnError> {
        guard WebAuthnPolicy.isAllowedOrigin(scheme: scheme, host: host), !WebAuthnPolicy.isIPAddress(host),
              let origin = WebAuthnPolicy.origin(scheme: scheme, host: host, port: port)
        else { return .failure(.security) }
        return .success((origin, host.lowercased()))
    }

    public static func create(_ body: [String: Any], scheme: String, host: String, port: Int,
                              suffixes: PublicSuffixList) -> Result<SecurityKeyCreateRequest, WebAuthnError> {
        let frame: (origin: String, host: String)
        switch origin(scheme: scheme, host: host, port: port) {
        case .success(let value): frame = value
        case .failure(let error): return .failure(error)
        }
        guard let challenge = (body["challenge"] as? String).flatMap(Base64URL.decode),
              let rp = body["rp"] as? [String: Any], let user = body["user"] as? [String: Any],
              let userID = (user["id"] as? String).flatMap(Base64URL.decode), (1...64).contains(userID.count),
              let exclude = credentialIDs(body["excludeCredentials"])
        else { return .failure(.notAllowed) }
        let rpId = ((rp["id"] as? String) ?? frame.host).lowercased()
        guard WebAuthnPolicy.isValidRPID(rpId, forHost: frame.host, suffixes: suffixes) else { return .failure(.security) }
        let selection = body["authenticatorSelection"] as? [String: Any] ?? [:]
        guard selection["authenticatorAttachment"] as? String != "platform" else { return .failure(.notAllowed) }
        let residentKey = requirement(selection["residentKey"])
            ?? (selection["requireResidentKey"] as? Bool == true ? .required : .discouraged)
        let algorithms: [Int]
        switch body["pubKeyCredParams"] {
        case nil: algorithms = []
        case let list as [Int]: algorithms = list
        default: return .failure(.notSupported)
        }
        return .success(SecurityKeyCreateRequest(
            rpId: rpId, rpName: rp["name"] as? String ?? "", userID: userID,
            userName: user["name"] as? String ?? "", userDisplayName: user["displayName"] as? String ?? "",
            clientDataJSON: WebAuthnClientData.json(.create, challenge: challenge, origin: frame.origin),
            algorithms: algorithms.isEmpty ? [-7, -257] : algorithms, excludeList: exclude,
            residentKey: residentKey, userVerification: requirement(selection["userVerification"]) ?? .preferred,
            credProps: body["credProps"] as? Bool == true, timeout: timeout(body["timeout"])))
    }

    public static func get(_ body: [String: Any], scheme: String, host: String, port: Int,
                           suffixes: PublicSuffixList) -> Result<SecurityKeyGetRequest, WebAuthnError> {
        let frame: (origin: String, host: String)
        switch origin(scheme: scheme, host: host, port: port) {
        case .success(let value): frame = value
        case .failure(let error): return .failure(error)
        }
        guard let challenge = (body["challenge"] as? String).flatMap(Base64URL.decode),
              let allow = credentialIDs(body["allowCredentials"])
        else { return .failure(.notAllowed) }
        let rpId = ((body["rpId"] as? String) ?? frame.host).lowercased()
        guard WebAuthnPolicy.isValidRPID(rpId, forHost: frame.host, suffixes: suffixes) else { return .failure(.security) }
        return .success(SecurityKeyGetRequest(
            rpId: rpId, clientDataJSON: WebAuthnClientData.json(.get, challenge: challenge, origin: frame.origin),
            allowList: allow, userVerification: requirement(body["userVerification"]) ?? .preferred,
            timeout: timeout(body["timeout"])))
    }

    /// The page's `timeout` in milliseconds, kept within 15 seconds and 10 minutes.
    public static func timeout(_ value: Any?) -> Duration {
        guard let milliseconds = value as? Double, milliseconds.isFinite, milliseconds > 0 else { return defaultTimeout }
        let requested = Duration.milliseconds(Int64(min(milliseconds, 86_400_000)))
        return min(max(requested, timeoutRange.lowerBound), timeoutRange.upperBound)
    }

    private static func requirement(_ value: Any?) -> SecurityKeyRequirement? {
        (value as? String).flatMap(SecurityKeyRequirement.init(rawValue:))
    }

    private static func credentialIDs(_ value: Any?) -> [Data]? {
        let ids = (value as? [String] ?? []).map(Base64URL.decode)
        return ids.allSatisfy { $0 != nil } ? ids.compactMap { $0 } : nil
    }
}

public enum SecurityKeyReply {
    public static func created(_ credential: SecurityKeyCreated, clientDataJSON: Data, credProps: Bool) -> [String: Any] {
        let extensions: [String: Any] = credProps ? ["credProps": ["rk": credential.residentKey]] : [:]
        return [
            "id": Base64URL.encode(credential.credentialID),
            "clientDataJSON": Base64URL.encode(clientDataJSON),
            "attestationObject": Base64URL.encode(credential.attestationObject),
            "authenticatorData": Base64URL.encode(credential.authenticatorData),
            "publicKeyAlgorithm": credential.publicKeyAlgorithm,
            "publicKey": credential.publicKey.map { Base64URL.encode($0) as Any } ?? NSNull() as Any,
            "transports": ["usb"],
            "authenticatorAttachment": "cross-platform",
            "clientExtensionResults": extensions,
        ]
    }

    public static func asserted(_ assertion: SecurityKeyAsserted, clientDataJSON: Data) -> [String: Any] {
        [
            "id": Base64URL.encode(assertion.credentialID),
            "clientDataJSON": Base64URL.encode(clientDataJSON),
            "authenticatorData": Base64URL.encode(assertion.authenticatorData),
            "signature": Base64URL.encode(assertion.signature),
            "userHandle": assertion.userHandle.map { Base64URL.encode($0) as Any } ?? NSNull() as Any,
            "authenticatorAttachment": "cross-platform",
            "clientExtensionResults": [String: Any](),
        ]
    }
}
