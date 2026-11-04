// Licensed under GPL-3.0. See LICENSE.
//
//  SecurityKeyRequestsCheck.swift
//  Nook
//
//  What a security key request is built from: the frame's origin (HTTPS, or HTTP on localhost;
//  never an IP address), an rpId the origin may claim under the Public Suffix List, the
//  clientDataJSON Nook writes, the page's options and timeout; and the reply dictionaries the
//  shim reads. Run from the repository root:
//
//    swiftc -parse-as-library \
//      Packages/NookWeb/Sources/NookWeb/SecurityKey/SecurityKeyRequests.swift \
//      Packages/NookWeb/Sources/NookWeb/Vault/{Base64URL,PublicSuffixList,VaultMessages,WebAuthnClientData,WebAuthnError,WebAuthnPolicy}.swift \
//      Packages/NookWeb/Checks/SecurityKeyRequestsCheck.swift -o /tmp/sk-requests && /tmp/sk-requests
//

import Foundation

@main
struct SecurityKeyRequestsCheck {
    static let psl = PublicSuffixList(text: try! String(
        contentsOfFile: "Packages/NookWeb/Sources/NookWeb/Resources/public_suffix_list.dat", encoding: .utf8))

    static func create(_ body: [String: Any], _ scheme: String = "https", _ host: String = "login.example.com", port: Int = 0)
        -> Result<SecurityKeyCreateRequest, WebAuthnError> {
        SecurityKeyOptions.create(body, scheme: scheme, host: host, port: port, suffixes: psl)
    }

    static func get(_ body: [String: Any], _ scheme: String = "https", _ host: String = "login.example.com", port: Int = 0)
        -> Result<SecurityKeyGetRequest, WebAuthnError> {
        SecurityKeyOptions.get(body, scheme: scheme, host: host, port: port, suffixes: psl)
    }

    static func error<T>(_ result: Result<T, WebAuthnError>) -> WebAuthnError? {
        if case .failure(let error) = result { return error }
        return nil
    }

    static func value<T>(_ result: Result<T, WebAuthnError>, line: UInt = #line) -> T {
        guard case .success(let value) = result else { preconditionFailure("\(result)", line: line) }
        return value
    }

    static let creation: [String: Any] = [
        "challenge": "AAEC",
        "rp": ["id": "example.com", "name": "Example"],
        "user": ["id": "dXNlcg", "name": "alice@example.com", "displayName": "Alice"],
        "pubKeyCredParams": [-7, -8],
        "excludeCredentials": ["qrvM"],
    ]

    static func with(_ base: [String: Any], _ changes: [String: Any]) -> [String: Any] {
        base.merging(changes) { $1 }
    }

    static func main() {
        // Origins: HTTPS anywhere but on IP addresses; HTTP only on localhost.
        precondition(value(SecurityKeyOptions.origin(scheme: "https", host: "Login.Example.com", port: 0)) == ("https://login.example.com", "login.example.com"))
        precondition(value(SecurityKeyOptions.origin(scheme: "https", host: "example.com", port: 8443)).origin == "https://example.com:8443")
        precondition(value(SecurityKeyOptions.origin(scheme: "http", host: "localhost", port: 3000)).origin == "http://localhost:3000")
        for (scheme, host) in [("http", "example.com"), ("http", "127.0.0.1"), ("https", "127.0.0.1"), ("https", "192.168.1.10"),
                               ("https", "::1"), ("https", "fe80::1"), ("http", "app.localhost"), ("file", ""), ("https", ""),
                               ("ftp", "example.com"), ("about", "blank")] {
            precondition(error(SecurityKeyOptions.origin(scheme: scheme, host: host, port: 0)) == .security, "\(scheme)://\(host)")
            precondition(error(create(creation, scheme, host)) == .security, "\(scheme)://\(host)")
            precondition(error(get(["challenge": "AAEC"], scheme, host)) == .security, "\(scheme)://\(host)")
        }

        // A full create: rpId, user, algorithms, exclusions, and clientDataJSON with WebKit's origin.
        let request = value(create(creation))
        precondition(request.rpId == "example.com" && request.rpName == "Example")
        precondition(request.userID == Data("user".utf8) && request.userName == "alice@example.com" && request.userDisplayName == "Alice")
        precondition(request.algorithms == [-7, -8] && request.excludeList == [Data([0xaa, 0xbb, 0xcc])])
        precondition(request.residentKey == .discouraged && request.userVerification == .preferred && !request.credProps)
        precondition(request.timeout == .seconds(300))
        precondition(String(decoding: request.clientDataJSON, as: UTF8.self)
            == #"{"type":"webauthn.create","challenge":"AAEC","origin":"https://login.example.com","crossOrigin":false}"#)
        precondition(request.clientDataHash == WebAuthnClientData.hash(request.clientDataJSON))
        precondition(value(create(with(creation, ["rp": ["name": "Local"]]), "http", "localhost", port: 8080)).clientDataJSON
            == WebAuthnClientData.json(.create, challenge: Data([0, 1, 2]), origin: "http://localhost:8080"))

        // rpId: the host or a registrable suffix of it; never a public suffix or another site.
        precondition(value(create(with(creation, ["rp": ["name": "Example"]]))).rpId == "login.example.com")
        precondition(value(create(with(creation, ["rp": ["id": "LOGIN.Example.COM"]]))).rpId == "login.example.com")
        precondition(value(create(with(creation, ["rp": ["id": "example.co.uk"]]), "https", "a.example.co.uk")).rpId == "example.co.uk")
        precondition(value(create(with(creation, ["rp": ["id": "localhost"]]), "http", "localhost")).rpId == "localhost")
        for (host, rpId) in [("login.example.com", "com"), ("login.example.com", "evil.com"), ("login.example.com", "ample.com"),
                             ("login.example.com", "sub.login.example.com"), ("a.example.co.uk", "co.uk"),
                             ("user.github.io", "github.io"), ("login.example.com", "example.com.")] {
            precondition(error(create(with(creation, ["rp": ["id": rpId]]), "https", host)) == .security, "\(rpId) for \(host)")
            precondition(error(get(["challenge": "AAEC", "rpId": rpId], "https", host)) == .security, "\(rpId) for \(host)")
        }

        // Options.
        let selection: [([String: Any], SecurityKeyRequirement)] = [
            (["residentKey": "required"], .required), (["requireResidentKey": true], .required),
            (["residentKey": "preferred", "requireResidentKey": true], .preferred), (["residentKey": "discouraged"], .discouraged),
            (["residentKey": "sometimes", "requireResidentKey": true], .required), ([:], .discouraged),
        ]
        for (options, expected) in selection {
            precondition(value(create(with(creation, ["authenticatorSelection": options]))).residentKey == expected, "\(options)")
        }
        let required = value(create(with(creation, ["authenticatorSelection": ["userVerification": "required"], "credProps": true])))
        precondition(required.userVerification == .required && required.credProps)
        precondition(value(create(with(creation, ["authenticatorSelection": ["authenticatorAttachment": "cross-platform"]]))).rpId == "example.com")
        precondition(error(create(with(creation, ["authenticatorSelection": ["authenticatorAttachment": "platform"]]))) == .notAllowed)
        precondition(value(create(with(creation, ["pubKeyCredParams": [Int]()]))).algorithms == [-7, -257])
        precondition(value(create(creation.filter { $0.key != "pubKeyCredParams" })).algorithms == [-7, -257])
        for malformed: Any in [[-7, "x"] as [Any], "-7", [NSNull()], ["alg": -7]] {
            precondition(error(create(with(creation, ["pubKeyCredParams": malformed]))) == .notSupported, "\(malformed)")
        }

        // Malformed input from the page.
        for broken: [String: Any] in [
            with(creation, ["challenge": "A"]), with(creation, ["challenge": "AA=="]),
            with(creation, ["user": ["id": ""]]), with(creation, ["user": ["id": Base64URL.encode(Data(count: 65))]]),
            with(creation, ["excludeCredentials": ["qrvM", "*"]]), with(creation, ["rp": "example.com"]),
        ] {
            precondition(error(create(broken)) == .notAllowed, "\(broken)")
        }
        precondition(error(get(["challenge": "AAEC", "allowCredentials": ["!"]])) == .notAllowed)
        precondition(error(get([:])) == .notAllowed)

        // get: rpId defaults to the host; allowCredentials; userVerification; clientDataJSON type.
        let assertion = value(get(["challenge": "AAEC", "rpId": "example.com", "allowCredentials": ["qrvM", "AQ"],
                                   "userVerification": "discouraged", "timeout": 45000.0]))
        precondition(assertion.rpId == "example.com" && assertion.allowList == [Data([0xaa, 0xbb, 0xcc]), Data([1])])
        precondition(assertion.userVerification == .discouraged && assertion.timeout == .seconds(45))
        precondition(String(decoding: assertion.clientDataJSON, as: UTF8.self)
            == #"{"type":"webauthn.get","challenge":"AAEC","origin":"https://login.example.com","crossOrigin":false}"#)
        precondition(value(get(["challenge": "AAEC"])).rpId == "login.example.com")
        precondition(value(get(["challenge": "AAEC", "userVerification": "maybe"])).userVerification == .preferred)

        // Timeouts, in milliseconds, kept to 15 seconds ... 10 minutes.
        precondition(SecurityKeyOptions.timeout(nil) == .seconds(300) && SecurityKeyOptions.timeout("60000") == .seconds(300))
        precondition(SecurityKeyOptions.timeout(1000.0) == .seconds(15) && SecurityKeyOptions.timeout(120_000.0) == .seconds(120))
        precondition(SecurityKeyOptions.timeout(NSNumber(value: 90_000)) == .seconds(90))
        precondition(SecurityKeyOptions.timeout(1e12) == .seconds(600) && SecurityKeyOptions.timeout(Double.infinity) == .seconds(300))
        precondition(SecurityKeyOptions.timeout(-5.0) == .seconds(300) && SecurityKeyOptions.timeout(Double.nan) == .seconds(300))

        // Replies, as the shim reads them.
        let clientData = Data("{}".utf8)
        let made = SecurityKeyCreated(credentialID: Data([0xfb, 0xff]), authenticatorData: Data([1, 2]), attestationObject: Data([3]),
                                      publicKeyAlgorithm: -7, publicKey: Data([4, 5]), residentKey: true)
        let createdReply = SecurityKeyReply.created(made, clientDataJSON: clientData, credProps: true) as NSDictionary
        precondition(createdReply == [
            "id": "-_8", "clientDataJSON": "e30", "attestationObject": "Aw", "authenticatorData": "AQI",
            "publicKeyAlgorithm": -7, "publicKey": "BAU", "transports": ["usb"], "authenticatorAttachment": "cross-platform",
            "clientExtensionResults": ["credProps": ["rk": true]],
        ] as NSDictionary, "\(createdReply)")
        let bare = SecurityKeyCreated(credentialID: Data([1]), authenticatorData: Data(), attestationObject: Data(),
                                      publicKeyAlgorithm: -257, publicKey: nil, residentKey: false)
        let bareReply = SecurityKeyReply.created(bare, clientDataJSON: clientData, credProps: false)
        precondition(bareReply["publicKey"] is NSNull && (bareReply["clientExtensionResults"] as? [String: Any])?.isEmpty == true)
        precondition(JSONSerialization.isValidJSONObject(bareReply) && JSONSerialization.isValidJSONObject(createdReply))

        let signed = SecurityKeyAsserted(credentialID: Data([1]), authenticatorData: Data([2]), signature: Data([3]), userHandle: Data([4]))
        precondition(SecurityKeyReply.asserted(signed, clientDataJSON: clientData) as NSDictionary == [
            "id": "AQ", "clientDataJSON": "e30", "authenticatorData": "Ag", "signature": "Aw", "userHandle": "BA",
            "authenticatorAttachment": "cross-platform", "clientExtensionResults": [String: Any](),
        ] as NSDictionary)
        let anonymous = SecurityKeyAsserted(credentialID: Data([1]), authenticatorData: Data([2]), signature: Data([3]), userHandle: nil)
        precondition(SecurityKeyReply.asserted(anonymous, clientDataJSON: clientData)["userHandle"] is NSNull)

        print("SecurityKeyRequestsCheck passed")
    }
}
