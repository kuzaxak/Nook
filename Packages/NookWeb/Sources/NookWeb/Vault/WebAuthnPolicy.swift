// Licensed under GPL-3.0. See LICENSE.
//
//  WebAuthnPolicy.swift
//  Nook
//
//  Which pages may use the Pawl Vault bridge, and for which relying party. Inputs come from
//  WebKit (`WKFrameInfo.securityOrigin`, the web view's URL), never from page script.
//

import Foundation

public enum WebAuthnPolicy {
    /// `scheme://host[:port]`, lowercase, without a default port. WebKit reports a default port as 0.
    public static func origin(scheme: String, host: String, port: Int) -> String? {
        let scheme = scheme.lowercased(), host = host.lowercased()
        guard !scheme.isEmpty, !host.isEmpty else { return nil }
        let bracketed = host.contains(":") ? "[\(host)]" : host
        let isDefault = port == 0 || (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        return "\(scheme)://\(bracketed)" + (isDefault ? "" : ":\(port)")
    }

    public static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host(percentEncoded: false) else { return nil }
        return origin(scheme: scheme, host: host, port: url.port ?? 0)
    }

    /// HTTPS, or HTTP on `localhost` and `127.0.0.1` only.
    public static func isAllowedOrigin(scheme: String, host: String) -> Bool {
        let host = host.lowercased()
        switch scheme.lowercased() {
        case "https": return !host.isEmpty
        case "http": return host == "localhost" || host == "127.0.0.1"
        default: return false
        }
    }

    /// The main frame, or a frame whose origin is the main frame's.
    public static func isAllowedFrame(isMainFrame: Bool, frameOrigin: String, mainFrameOrigin: String?) -> Bool {
        isMainFrame || frameOrigin == mainFrameOrigin
    }

    /// `rpId` equals `host`, or is a suffix of it at a label boundary that is neither the host's
    /// public suffix nor part of it (HTML's "is a registrable domain suffix of or is equal to").
    public static func isValidRPID(_ rpId: String, forHost host: String, suffixes: PublicSuffixList) -> Bool {
        let rpId = rpId.lowercased(), host = host.lowercased()
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-.".utf8)
        guard rpId.utf8.allSatisfy(allowed.contains),
              !rpId.split(separator: ".", omittingEmptySubsequences: false).contains(where: \.isEmpty)
        else { return false }
        if rpId == host { return true }
        guard !isIPAddress(host), host.hasSuffix("." + rpId) else { return false }
        let hostSuffix = suffixes.publicSuffix(of: host)
        return rpId != hostSuffix && !hostSuffix.hasSuffix("." + rpId)
    }

    private static func isIPAddress(_ host: String) -> Bool {
        host.contains(":") || host.split(separator: ".").allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}
