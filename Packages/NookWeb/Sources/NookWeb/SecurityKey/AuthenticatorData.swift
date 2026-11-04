// Licensed under GPL-3.0. See LICENSE.
//
//  AuthenticatorData.swift
//  Nook
//
//  WebAuthn authenticator data (§6.1) as a security key returns it: the rpId hash, flags, the
//  signature counter, and on registration the new credential's id and COSE public key. Nook
//  checks these before a reply reaches the page, and turns the COSE key into the SPKI that
//  `getPublicKey()` returns.
//

import CryptoKit
import Foundation

public struct AuthenticatorData {
    public struct AttestedCredential {
        public let aaguid: Data
        public let credentialID: Data
        public let publicKey: CBOR
    }

    public let raw: Data
    public let rpIdHash: Data
    public let flags: UInt8
    public let signCount: UInt32
    public let attestedCredential: AttestedCredential?

    public var userPresent: Bool { flags & 0x01 != 0 }
    public var userVerified: Bool { flags & 0x04 != 0 }

    public struct Malformed: Error {}

    public init(_ data: Data) throws {
        let bytes = Data(data)
        guard bytes.count >= 37 else { throw Malformed() }
        raw = bytes
        rpIdHash = bytes.subdata(in: 0..<32)
        flags = bytes[32]
        signCount = bytes[33..<37].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        var offset = 37
        if flags & 0x40 != 0 {
            guard bytes.count >= offset + 18 else { throw Malformed() }
            let aaguid = bytes.subdata(in: offset..<offset + 16)
            let length = Int(bytes[offset + 16]) << 8 | Int(bytes[offset + 17])
            offset += 18
            guard length > 0, bytes.count >= offset + length else { throw Malformed() }
            let credentialID = bytes.subdata(in: offset..<offset + length)
            offset += length
            guard let key = try? CBOR.decode(bytes, from: &offset), key.map != nil else { throw Malformed() }
            attestedCredential = AttestedCredential(aaguid: aaguid, credentialID: credentialID, publicKey: key)
        } else {
            attestedCredential = nil
        }
        if flags & 0x80 != 0 {
            guard (try? CBOR.decode(bytes, from: &offset))?.map != nil else { throw Malformed() }
        }
        guard offset == bytes.count else { throw Malformed() }
    }

    public func belongs(to rpId: String) -> Bool {
        rpIdHash == Data(SHA256.hash(data: Data(rpId.utf8)))
    }

    /// The same bytes with a zero AAGUID, so the page cannot tell the key's make and model.
    public var anonymized: Data {
        guard attestedCredential != nil else { return raw }
        var copy = raw
        copy.replaceSubrange(37..<53, with: Data(count: 16))
        return copy
    }

    /// A "none" attestation object over `authenticatorData`.
    public static func noneAttestationObject(_ authenticatorData: Data) -> Data {
        CBOR.map([.text("fmt"): .text("none"), .text("attStmt"): .map([:]), .text("authData"): .bytes(authenticatorData)]).encoded
    }
}

public enum COSEKey {
    /// The key's COSE algorithm, from its `3` member.
    public static func algorithm(_ key: CBOR) -> Int? { key[3]?.int }

    /// DER SubjectPublicKeyInfo for EC2 P-256/384/521 and OKP Ed25519 keys; nil for others,
    /// for which `getPublicKey()` returns null.
    public static func subjectPublicKeyInfo(_ key: CBOR) -> Data? {
        switch (key[1]?.int, key[-1]?.int) {
        case (2, 1?), (2, 2?), (2, 3?):
            guard let x = key[-2]?.bytes, let y = key[-3]?.bytes, x.count == y.count else { return nil }
            let point = Data([0x04]) + x + y
            switch key[-1]?.int {
            case 1: return (try? P256.Signing.PublicKey(x963Representation: point))?.derRepresentation
            case 2: return (try? P384.Signing.PublicKey(x963Representation: point))?.derRepresentation
            default: return (try? P521.Signing.PublicKey(x963Representation: point))?.derRepresentation
            }
        case (1, 6?):
            guard let x = key[-2]?.bytes, x.count == 32 else { return nil }
            return Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00]) + x
        default:
            return nil
        }
    }
}
