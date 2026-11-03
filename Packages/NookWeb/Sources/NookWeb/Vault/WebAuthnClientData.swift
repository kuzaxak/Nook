// Licensed under GPL-3.0. See LICENSE.
//
//  WebAuthnClientData.swift
//  Nook
//
//  The clientDataJSON Nook builds for every passkey request. The origin comes from WebKit,
//  never from the page; the vault only ever sees the SHA-256 of these bytes.
//

import CryptoKit
import Foundation

public enum WebAuthnClientData {
    public enum Kind: String {
        case get = "webauthn.get"
        case create = "webauthn.create"
    }

    /// `{"type":…,"challenge":…,"origin":…,"crossOrigin":false}` in that key order, as the
    /// WebAuthn "CollectedClientData" serialization requires.
    public static func json(_ kind: Kind, challenge: Data, origin: String) -> Data {
        let text = "{\"type\":" + string(kind.rawValue)
            + ",\"challenge\":" + string(Base64URL.encode(challenge))
            + ",\"origin\":" + string(origin)
            + ",\"crossOrigin\":false}"
        return Data(text.utf8)
    }

    public static func hash(_ clientDataJSON: Data) -> Data {
        Data(SHA256.hash(data: clientDataJSON))
    }

    /// WebAuthn's JSON string serialization: `"` and `\` escaped, other code points below
    /// U+0020 as `\u` and four lowercase hex digits, everything else as is.
    private static func string(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
