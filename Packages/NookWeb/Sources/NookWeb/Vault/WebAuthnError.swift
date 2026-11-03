// Licensed under GPL-3.0. See LICENSE.
//
//  WebAuthnError.swift
//  Nook
//
//  The DOMException name the passkey shim rejects with. WebAuthn reports nearly every failure
//  as NotAllowedError so a page cannot tell "no passkey" from "the user said no".
//

import Foundation

public enum WebAuthnError: String, Error {
    /// Cancelled, denied, locked, unpaired, unreachable vault, or a cross-origin frame.
    case notAllowed = "NotAllowedError"
    /// The origin is not allowed, or the rpId does not belong to it.
    case security = "SecurityError"
    /// The vault already holds one of `excludeCredentials`.
    case invalidState = "InvalidStateError"
    case abort = "AbortError"
    /// None of the requested algorithms is ES256.
    case notSupported = "NotSupportedError"

    public init(_ error: VaultClientError, creating: Bool) {
        // The vault answers an excluded credential on `register` with `denied` / "excluded".
        if creating, error == .server(.denied, "excluded") {
            self = .invalidState
        } else {
            self = .notAllowed
        }
    }
}
