// Licensed under GPL-3.0. See LICENSE.
//
//  VaultClientDataCheck.swift
//  Nook
//
//  The clientDataJSON Nook builds for a passkey request: exact bytes, key order, escaping, and
//  the SHA-256 that is all the vault ever sees:
//
//    swiftc -parse-as-library Packages/NookWeb/Sources/NookWeb/Vault/Base64URL.swift \
//           Packages/NookWeb/Sources/NookWeb/Vault/WebAuthnClientData.swift \
//           Packages/NookWeb/Checks/VaultClientDataCheck.swift -o /tmp/vault-clientdata && /tmp/vault-clientdata
//

import Foundation

@main
struct VaultClientDataCheck {
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    static func main() {
        let get = WebAuthnClientData.json(.get, challenge: Data([0, 1, 2]), origin: "https://example.com")
        precondition(String(decoding: get, as: UTF8.self)
            == #"{"type":"webauthn.get","challenge":"AAEC","origin":"https://example.com","crossOrigin":false}"#)
        precondition(hex(WebAuthnClientData.hash(get)) == "152ad90e8824d2b0b1e763a1fc72836c8fd114a4c3043df6b8c1e7c74249005e")

        let create = WebAuthnClientData.json(.create, challenge: Data([0xfb, 0xff]), origin: "http://localhost:8080")
        precondition(String(decoding: create, as: UTF8.self)
            == #"{"type":"webauthn.create","challenge":"-_8","origin":"http://localhost:8080","crossOrigin":false}"#)
        precondition(hex(WebAuthnClientData.hash(create)) == "032d840569b4122ebe6017874ec205419cf85d170bd1bfc10967bba6d27e53c0")

        // WebAuthn's JSON string serialization: quote and backslash escaped, controls as \u00xx.
        let odd = WebAuthnClientData.json(.get, challenge: Data(), origin: "https://a\"b\\c\u{01}\u{1f}é")
        precondition(String(decoding: odd, as: UTF8.self)
            == #"{"type":"webauthn.get","challenge":"","origin":"https://a\"b\\c\u0001\u001fé","crossOrigin":false}"#)
        precondition(WebAuthnClientData.hash(odd).count == 32)

        print("VaultClientDataCheck passed")
    }
}
