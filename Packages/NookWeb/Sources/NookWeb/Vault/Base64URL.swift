// Licensed under GPL-3.0. See LICENSE.
//
//  Base64URL.swift
//  Nook
//
//  Base64url without padding (RFC 4648 §5): credential ids, hashes, signatures and user
//  handles on the Pawl Vault bridge and in the passkey shim.
//

import Foundation

public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        var text = data.base64EncodedString()
        text = text.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        while text.hasSuffix("=") { text.removeLast() }
        return text
    }

    /// Nil for anything but unpadded base64url.
    public static func decode(_ text: String) -> Data? {
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)
        guard text.utf8.allSatisfy(alphabet.contains), text.utf8.count % 4 != 1 else { return nil }
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.utf8.count % 4) % 4)
        return Data(base64Encoded: standard)
    }
}
