// Licensed under GPL-3.0. See LICENSE.
//
//  PinUvAuthProtocol.swift
//  Nook
//
//  PIN/UV auth protocols one and two (CTAP 2.1 §6.5.6, §6.5.7): ECDH on P-256 with the key's
//  key-agreement key, the shared-secret KDF, AES-256-CBC and HMAC-SHA-256. Protocol two is used
//  whenever the key offers it.
//

import CommonCrypto
import CryptoKit
import Foundation

public struct PinUvAuthProtocol: Equatable {
    public let version: Int

    public static let one = PinUvAuthProtocol(version: 1)
    public static let two = PinUvAuthProtocol(version: 2)

    public enum Failure: Error, Equatable {
        case badKeyAgreement
        case badCiphertext
        case cryptoFailed
    }

    /// Two when the key lists it, else one, which is what keys that list nothing speak.
    public static func preferred(from versions: [Int]) -> PinUvAuthProtocol? {
        if versions.contains(2) { return .two }
        if versions.contains(1) || versions.isEmpty { return .one }
        return nil
    }

    // MARK: - Key agreement

    /// The platform's COSE key for `privateKey` and the shared secret with the key's `peer`.
    public func encapsulate(peer: CBOR, privateKey: P256.KeyAgreement.PrivateKey = .init()) throws -> (keyAgreement: CBOR, sharedSecret: Data) {
        guard peer[1]?.int == 2, peer[-1]?.int == 1,
              let x = peer[-2]?.bytes, let y = peer[-3]?.bytes, x.count == 32, y.count == 32,
              let peerKey = try? P256.KeyAgreement.PublicKey(x963Representation: Data([0x04]) + x + y),
              let shared = try? privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        else { throw Failure.badKeyAgreement }
        var z = shared.withUnsafeBytes { Data($0) }
        defer { zeroize(&z) }
        return (Self.coseKey(privateKey.publicKey), kdf(z))
    }

    /// `{1: 2, 3: -25, -1: 1, -2: x, -3: y}`, the form CTAP uses for a key-agreement key.
    public static func coseKey(_ key: P256.KeyAgreement.PublicKey) -> CBOR {
        let point = key.x963Representation
        return .map([.int(1): .int(2), .int(3): .int(-25), .int(-1): .int(1),
                     .int(-2): .bytes(point.subdata(in: 1..<33)), .int(-3): .bytes(point.subdata(in: 33..<65))])
    }

    public func kdf(_ z: Data) -> Data {
        guard version == 2 else { return Data(SHA256.hash(data: z)) }
        let ikm = SymmetricKey(data: z)
        let salt = Data(repeating: 0, count: 32)
        func derive(_ info: String) -> Data {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data(info.utf8), outputByteCount: 32)
                .withUnsafeBytes { Data($0) }
        }
        return derive("CTAP2 HMAC key") + derive("CTAP2 AES key")
    }

    // MARK: - Encrypt, decrypt, authenticate

    /// Protocol one: AES-256-CBC with a zero IV. Protocol two: a random IV (or `iv`) and the AES
    /// half of the secret, the IV first in the output.
    public func encrypt(key: Data, plaintext: Data, iv: Data? = nil) throws -> Data {
        guard plaintext.count % 16 == 0 else { throw Failure.cryptoFailed }
        if version == 1 {
            return try Self.aes(CCOperation(kCCEncrypt), key: key, iv: Data(count: 16), input: plaintext)
        }
        guard key.count == 64 else { throw Failure.cryptoFailed }
        let iv = try iv ?? Self.randomIV()
        return iv + (try Self.aes(CCOperation(kCCEncrypt), key: key.subdata(in: 32..<64), iv: iv, input: plaintext))
    }

    public func decrypt(key: Data, ciphertext: Data) throws -> Data {
        if version == 1 {
            guard !ciphertext.isEmpty, ciphertext.count % 16 == 0 else { throw Failure.badCiphertext }
            return try Self.aes(CCOperation(kCCDecrypt), key: key, iv: Data(count: 16), input: ciphertext)
        }
        guard key.count == 64, ciphertext.count > 16, ciphertext.count % 16 == 0 else { throw Failure.badCiphertext }
        let bytes = Data(ciphertext)
        return try Self.aes(CCOperation(kCCDecrypt), key: key.subdata(in: 32..<64), iv: bytes.prefix(16), input: bytes.dropFirst(16))
    }

    /// HMAC-SHA-256 of `message`: the first 16 bytes for protocol one; for protocol two all 32,
    /// keyed by the HMAC half of a shared secret or by a whole token.
    public func authenticate(key: Data, message: Data) -> Data {
        let hmacKey = version == 2 && key.count == 64 ? key.prefix(32) : key
        let mac = Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: hmacKey)))
        return version == 1 ? mac.prefix(16) : mac
    }

    /// LEFT(SHA-256(pin), 16), as `getPinToken` and its successors send it.
    public static func pinHash(_ pin: Data) -> Data {
        Data(SHA256.hash(data: pin)).prefix(16)
    }

    private static func randomIV() throws -> Data {
        var iv = Data(count: 16)
        let status = iv.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw Failure.cryptoFailed }
        return iv
    }

    private static func aes(_ operation: CCOperation, key: Data, iv: Data, input: Data) throws -> Data {
        guard key.count == kCCKeySizeAES256, iv.count == kCCBlockSizeAES128 else { throw Failure.cryptoFailed }
        var output = Data(count: input.count)
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    input.withUnsafeBytes { inBytes in
                        CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), 0,
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                inBytes.baseAddress, input.count, out.baseAddress, input.count, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess, moved == input.count else { throw Failure.cryptoFailed }
        return output
    }
}

/// Overwrites `data` with zeros where it lives.
func zeroize(_ data: inout Data) {
    let count = data.count
    data.withUnsafeMutableBytes { bytes in
        guard let base = bytes.baseAddress else { return }
        _ = memset_s(base, count, 0, count)
    }
}
