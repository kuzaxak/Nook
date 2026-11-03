// Licensed under GPL-3.0. See LICENSE.
//
//  VaultBase64URLCheck.swift
//  Nook
//
//  Base64url without padding, the encoding of every binary value on the Pawl Vault bridge:
//
//    swiftc -parse-as-library Packages/NookWeb/Sources/NookWeb/Vault/Base64URL.swift \
//           Packages/NookWeb/Checks/VaultBase64URLCheck.swift -o /tmp/vault-b64 && /tmp/vault-b64
//

import Foundation

@main
struct VaultBase64URLCheck {
    static func main() {
        let vectors: [([UInt8], String)] = [
            ([], ""),
            (Array("f".utf8), "Zg"),
            (Array("fo".utf8), "Zm8"),
            (Array("foo".utf8), "Zm9v"),
            (Array("foob".utf8), "Zm9vYg"),
            ([0xfb, 0xff], "-_8"),
            ([0xff, 0xfe, 0xfd, 0xfc], "__79_A"),
        ]
        for (bytes, text) in vectors {
            precondition(Base64URL.encode(Data(bytes)) == text, "encode \(bytes)")
            precondition(Base64URL.decode(text) == Data(bytes), "decode \(text)")
        }

        var generator = SystemRandomNumberGenerator()
        for length in 0...130 {
            let data = Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) })
            let text = Base64URL.encode(data)
            precondition(!text.contains("=") && !text.contains("+") && !text.contains("/"), text)
            precondition(Base64URL.decode(text) == data, "round trip \(length)")
        }

        for bad in ["Zg==", "Zm9v+A", "Zm9v/A", "Z", "Zm9vY", "Zm 9v", "Zm9v\n", "é"] {
            precondition(Base64URL.decode(bad) == nil, "accepted \(bad)")
        }
        print("VaultBase64URLCheck passed")
    }
}
