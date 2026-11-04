// Licensed under GPL-3.0. See LICENSE.
//
//  VaultWebAuthnPolicyCheck.swift
//  Nook
//
//  Origin, frame and rpId rules for passkey requests, against the bundled Public Suffix List.
//  Run from the repository root:
//
//    swiftc -parse-as-library Packages/NookWeb/Sources/NookWeb/Vault/PublicSuffixList.swift \
//           Packages/NookWeb/Sources/NookWeb/Vault/WebAuthnPolicy.swift \
//           Packages/NookWeb/Checks/VaultWebAuthnPolicyCheck.swift -o /tmp/vault-policy && /tmp/vault-policy
//

import Foundation

@main
struct VaultWebAuthnPolicyCheck {
    static func main() throws {
        let text = try String(contentsOfFile: "Packages/NookWeb/Sources/NookWeb/Resources/public_suffix_list.dat", encoding: .utf8)
        let psl = PublicSuffixList(text: text)

        // Punycode (RFC 3492), so IDN rules match the ASCII hosts WebKit reports.
        precondition(PublicSuffixList.asciiLabel("example") == "example")
        precondition(PublicSuffixList.asciiLabel("bücher") == "xn--bcher-kva")
        precondition(PublicSuffixList.asciiLabel("公司") == "xn--55qx5d")
        precondition(PublicSuffixList.asciiLabel("3年B組金八先生") == "xn--3B-ww4c5e180e575a65lsy2b")

        // Public suffixes: plain, wildcard, exception, private section, IDN, unknown TLD.
        precondition(psl.publicSuffix(of: "www.example.co.uk") == "co.uk")
        precondition(psl.publicSuffix(of: "example.com") == "com")
        precondition(psl.publicSuffix(of: "user.github.io") == "github.io")
        precondition(psl.publicSuffix(of: "a.b.kawasaki.jp") == "b.kawasaki.jp")
        precondition(psl.publicSuffix(of: "x.city.kawasaki.jp") == "kawasaki.jp")
        precondition(psl.publicSuffix(of: "a.www.ck") == "ck")
        precondition(psl.publicSuffix(of: "a.foo.ck") == "foo.ck")
        precondition(psl.publicSuffix(of: "shop.xn--55qx5d.cn") == "xn--55qx5d.cn")
        precondition(psl.publicSuffix(of: "example.notatld") == "notatld")
        for suffix in ["com", "co.uk", "github.io", "uk", "xn--55qx5d.cn"] { precondition(psl.isPublicSuffix(suffix), suffix) }
        for domain in ["example.com", "example.co.uk", "user.github.io"] { precondition(!psl.isPublicSuffix(domain), domain) }

        // Origins are built from WKSecurityOrigin parts; port 0 and default ports are left out.
        precondition(WebAuthnPolicy.origin(scheme: "https", host: "Example.com", port: 0) == "https://example.com")
        precondition(WebAuthnPolicy.origin(scheme: "https", host: "example.com", port: 443) == "https://example.com")
        precondition(WebAuthnPolicy.origin(scheme: "https", host: "example.com", port: 8443) == "https://example.com:8443")
        precondition(WebAuthnPolicy.origin(scheme: "http", host: "localhost", port: 3000) == "http://localhost:3000")
        precondition(WebAuthnPolicy.origin(scheme: "https", host: "", port: 0) == nil)
        precondition(WebAuthnPolicy.origin(of: URL(string: "https://Login.Example.com:443/path?q")!) == "https://login.example.com")
        precondition(WebAuthnPolicy.origin(of: URL(string: "http://127.0.0.1:8080/")!) == "http://127.0.0.1:8080")

        // HTTPS anywhere; HTTP only on localhost and 127.0.0.1.
        precondition(WebAuthnPolicy.isAllowedOrigin(scheme: "https", host: "example.com"))
        precondition(WebAuthnPolicy.isAllowedOrigin(scheme: "http", host: "localhost"))
        precondition(WebAuthnPolicy.isAllowedOrigin(scheme: "http", host: "127.0.0.1"))
        for (scheme, host) in [("http", "example.com"), ("http", "app.localhost"), ("http", "127.0.0.2"),
                               ("file", ""), ("ftp", "example.com"), ("https", ""), ("about", "")] {
            precondition(!WebAuthnPolicy.isAllowedOrigin(scheme: scheme, host: host), "\(scheme)://\(host)")
        }

        // Main frame, or a frame with the main frame's origin and only that origin above it; never a
        // cross-origin iframe, and never a same-origin frame inside a cross-origin one (A > B > A).
        let a = "https://a.com"
        precondition(WebAuthnPolicy.isAllowedFrame(isMainFrame: true, frameOrigin: a, mainFrameOrigin: a, ancestorOrigins: []))
        precondition(WebAuthnPolicy.isAllowedFrame(isMainFrame: true, frameOrigin: a, mainFrameOrigin: a, ancestorOrigins: nil))
        precondition(WebAuthnPolicy.isAllowedFrame(isMainFrame: false, frameOrigin: a, mainFrameOrigin: a, ancestorOrigins: [a]))
        precondition(WebAuthnPolicy.isAllowedFrame(isMainFrame: false, frameOrigin: a, mainFrameOrigin: a, ancestorOrigins: [a, "HTTPS://A.COM"]))
        precondition(!WebAuthnPolicy.isAllowedFrame(isMainFrame: false, frameOrigin: a, mainFrameOrigin: a, ancestorOrigins: ["https://b.com", a]))
        precondition(!WebAuthnPolicy.isAllowedFrame(isMainFrame: false, frameOrigin: a, mainFrameOrigin: a, ancestorOrigins: ["null", a]))
        precondition(!WebAuthnPolicy.isAllowedFrame(isMainFrame: false, frameOrigin: a, mainFrameOrigin: a, ancestorOrigins: []))
        precondition(!WebAuthnPolicy.isAllowedFrame(isMainFrame: false, frameOrigin: a, mainFrameOrigin: a, ancestorOrigins: nil))
        precondition(!WebAuthnPolicy.isAllowedFrame(isMainFrame: false, frameOrigin: "https://evil.com", mainFrameOrigin: a, ancestorOrigins: [a]))
        precondition(!WebAuthnPolicy.isAllowedFrame(isMainFrame: false, frameOrigin: "https://sub.a.com", mainFrameOrigin: a, ancestorOrigins: [a]))
        precondition(!WebAuthnPolicy.isAllowedFrame(isMainFrame: false, frameOrigin: a, mainFrameOrigin: nil, ancestorOrigins: [a]))

        // rpId: the host itself, or a registrable suffix of it at a label boundary.
        let ok: [(String, String)] = [
            ("login.example.com", "login.example.com"), ("login.example.com", "example.com"),
            ("login.example.com", "LOGIN.EXAMPLE.COM"), ("foo.example.co.uk", "example.co.uk"),
            ("user.github.io", "user.github.io"), ("x.city.kawasaki.jp", "city.kawasaki.jp"),
            ("a.www.ck", "www.ck"), ("login.example.xn--55qx5d.cn", "example.xn--55qx5d.cn"),
            ("localhost", "localhost"), ("127.0.0.1", "127.0.0.1"), ("github.io", "github.io"),
        ]
        for (host, rpId) in ok {
            precondition(WebAuthnPolicy.isValidRPID(rpId, forHost: host, suffixes: psl), "\(rpId) for \(host)")
        }
        let rejected: [(String, String)] = [
            ("login.example.com", "com"), ("foo.example.co.uk", "co.uk"), ("foo.example.co.uk", "uk"),
            ("user.github.io", "github.io"), ("user.github.io", "io"),
            ("example.com", "ample.com"), ("login.example.com", "ample.com"), ("example.com", "xample.com"),
            ("login.example.com", "example.org"), ("example.com", "login.example.com"),
            ("a.b.kawasaki.jp", "b.kawasaki.jp"), ("a.b.kawasaki.jp", "kawasaki.jp"), ("a.foo.ck", "foo.ck"),
            ("example.xn--55qx5d.cn", "xn--55qx5d.cn"), ("login.example.com", ""),
            ("login.example.com", "example.com."), ("login.example.com", ".example.com"),
            ("login.example.com", "exa mple.com"), ("login.example.com", "éxample.com"),
            ("127.0.0.1", "0.0.1"), ("10.0.0.1", "0.1"),
        ]
        for (host, rpId) in rejected {
            precondition(!WebAuthnPolicy.isValidRPID(rpId, forHost: host, suffixes: psl), "\(rpId) for \(host)")
        }

        // A list that failed to load fails closed: only the host itself.
        let missing = PublicSuffixList(text: "")
        precondition(WebAuthnPolicy.isValidRPID("login.example.com", forHost: "login.example.com", suffixes: missing))
        precondition(!WebAuthnPolicy.isValidRPID("example.com", forHost: "login.example.com", suffixes: missing))
        precondition(!WebAuthnPolicy.isValidRPID("example.co.uk", forHost: "foo.example.co.uk", suffixes: missing))

        print("VaultWebAuthnPolicyCheck passed")
    }
}
