// Licensed under GPL-3.0. See LICENSE.
//
//  VaultMessagesCheck.swift
//  Nook
//
//  Bridge protocol v1 messages: each request against the protocol's examples, each reply and
//  error envelope, per-method timeouts, the status line, and vault errors as DOMException names.
//  Amendment 4 adds `hasCode` on logins (absent from older vaults) and the `code` method:
//
//    swiftc -parse-as-library Packages/NookWeb/Sources/NookWeb/Vault/VaultMessages.swift \
//           Packages/NookWeb/Sources/NookWeb/Vault/WebAuthnError.swift \
//           Packages/NookWeb/Checks/VaultMessagesCheck.swift -o /tmp/vault-messages && /tmp/vault-messages
//

import Foundation

@main
struct VaultMessagesCheck {
    static func object(_ data: Data) -> NSDictionary {
        try! JSONSerialization.jsonObject(with: data) as! NSDictionary
    }

    static func expect<C: VaultCall>(_ call: C, id: Int, _ json: String) throws {
        let line = try VaultCodec.encode(call, id: id)
        precondition(!line.contains(0x0a), "a request is one line")
        precondition(object(line) == object(Data(json.utf8)), "\(C.method): \(String(decoding: line, as: UTF8.self))")
    }

    static func reply<C: VaultCall>(_ type: C.Type, _ json: String) throws -> C.Reply {
        try VaultCodec.decode(Data(json.utf8), for: type)
    }

    static func main() throws {
        let profile = "6F9619FF-8B86-D011-B42D-00C04FC964FF"

        // Requests, as in the protocol's Methods section.
        try expect(VaultHello(profile: profile), id: 1,
                   #"{"id":1,"method":"hello","params":{"client":"Nook","version":1,"profile":"6F9619FF-8B86-D011-B42D-00C04FC964FF"}}"#)
        try expect(VaultHello(profile: nil), id: 1, #"{"id":1,"method":"hello","params":{"client":"Nook","version":1}}"#)
        try expect(VaultLogins(origin: "https://accounts.example.com", profile: ""), id: 7,
                   #"{"id":7,"method":"logins","params":{"origin":"https://accounts.example.com","profile":""}}"#)
        try expect(VaultPassword(id: "E1", origin: "https://accounts.example.com", profile: profile), id: 8,
                   #"{"id":8,"method":"password","params":{"id":"E1","origin":"https://accounts.example.com","profile":"6F9619FF-8B86-D011-B42D-00C04FC964FF"}}"#)
        try expect(VaultCode(id: "E1", origin: "https://accounts.example.com", profile: nil), id: 14,
                   #"{"id":14,"method":"code","params":{"id":"E1","origin":"https://accounts.example.com"}}"#)
        try expect(VaultSave(origin: "https://a.com", username: "me", password: "p\"w", profile: nil), id: 9,
                   #"{"id":9,"method":"save","params":{"origin":"https://a.com","username":"me","password":"p\"w"}}"#)
        try expect(VaultPasskeys(rpId: "example.com", allowCredentials: ["AAEC", "-_8"], profile: nil), id: 10,
                   #"{"id":10,"method":"passkeys","params":{"rpId":"example.com","allowCredentials":["AAEC","-_8"]}}"#)
        try expect(VaultPasskeys(rpId: "example.com", allowCredentials: [], profile: nil), id: 11,
                   #"{"id":11,"method":"passkeys","params":{"rpId":"example.com","allowCredentials":[]}}"#)
        try expect(VaultAssert(rpId: "example.com", credentialId: "AAEC", clientDataHash: "FSrZ",
                               userVerification: "preferred", origin: "https://example.com", profile: nil), id: 12,
                   #"{"id":12,"method":"assert","params":{"rpId":"example.com","credentialId":"AAEC","clientDataHash":"FSrZ","userVerification":"preferred","origin":"https://example.com"}}"#)
        try expect(VaultRegister(rpId: "example.com", rpName: "Example",
                                 user: .init(id: "dXNlcg", name: "me@example.com", displayName: "Me"),
                                 clientDataHash: "FSrZ", pubKeyCredParams: [-7, -8, -257], excludeCredentials: ["AAEC"],
                                 origin: "https://example.com", profile: profile), id: 13,
                   #"{"id":13,"method":"register","params":{"rpId":"example.com","rpName":"Example","user":{"id":"dXNlcg","name":"me@example.com","displayName":"Me"},"clientDataHash":"FSrZ","pubKeyCredParams":[-7,-8,-257],"excludeCredentials":["AAEC"],"origin":"https://example.com","profile":"6F9619FF-8B86-D011-B42D-00C04FC964FF"}}"#)

        // Timeouts: 5 s for lookups, 120 s for anything that waits for Touch ID.
        precondition(VaultHello.timeout == 5 && VaultLogins.timeout == 5 && VaultPasskeys.timeout == 5)
        precondition(VaultPassword.timeout == 120 && VaultCode.timeout == 120 && VaultSave.timeout == 120)
        precondition(VaultAssert.timeout == 120 && VaultRegister.timeout == 120)

        // Replies.
        precondition(VaultCodec.responseID(Data(#"{"id":7,"result":{}}"#.utf8)) == 7)
        precondition(VaultCodec.responseID(Data("not json".utf8)) == nil)
        let hello = try reply(VaultHello.self, #"{"id":1,"result":{"vault":"Pawl Vault","version":1,"paired":true,"unlocked":false}}"#)
        precondition(hello.vault == "Pawl Vault" && hello.version == 1 && hello.paired && !hello.unlocked)
        let logins = try reply(VaultLogins.self, #"{"id":7,"result":{"logins":[{"id":"E1","username":"me","title":"Example"}]}}"#)
        precondition(logins.logins == [VaultLogin(id: "E1", username: "me", title: "Example")])
        precondition(!logins.logins[0].hasCode, "a vault without one-time codes leaves hasCode out")
        let coded = try reply(VaultLogins.self, #"{"id":7,"result":{"logins":[{"id":"E1","username":"me","title":"Example","hasCode":true},{"id":"E2","username":"you","title":"Example","hasCode":false}]}}"#)
        precondition(coded.logins == [VaultLogin(id: "E1", username: "me", title: "Example", hasCode: true),
                                      VaultLogin(id: "E2", username: "you", title: "Example", hasCode: false)])
        precondition(coded.logins.map(\.hasCode) == [true, false])
        let password = try reply(VaultPassword.self, #"{"id":8,"result":{"username":"me","password":"secret"}}"#)
        precondition(password.username == "me" && password.password == "secret")
        let code = try reply(VaultCode.self, #"{"id":14,"result":{"code":"012345","remaining":17}}"#)
        precondition(code.code == "012345" && code.remaining == 17)
        let saved = try reply(VaultSave.self, #"{"id":9,"result":{"saved":true,"id":"E2"}}"#)
        precondition(saved.saved && saved.id == "E2")
        let passkeys = try reply(VaultPasskeys.self, #"{"id":10,"result":{"passkeys":[{"credentialId":"AAEC","userName":"me","title":"Example"}]}}"#)
        precondition(passkeys.passkeys == [VaultPasskey(credentialId: "AAEC", userName: "me", title: "Example")])
        let assertion = try reply(VaultAssert.self, #"{"id":12,"result":{"credentialId":"AAEC","authenticatorData":"YXV0aA","signature":"c2ln","userHandle":"dXNlcg"}}"#)
        precondition(assertion.credentialId == "AAEC" && assertion.authenticatorData == "YXV0aA"
                     && assertion.signature == "c2ln" && assertion.userHandle == "dXNlcg")
        let registration = try reply(VaultRegister.self, #"{"id":13,"result":{"credentialId":"AAEC","attestationObject":"YXR0","authenticatorData":"YXV0aA","publicKeyAlgorithm":-7}}"#)
        precondition(registration.credentialId == "AAEC" && registration.attestationObject == "YXR0"
                     && registration.authenticatorData == "YXV0aA" && registration.publicKeyAlgorithm == -7)

        // Error envelopes; an unknown code reads as internal.
        let codes: [(String, VaultErrorCode)] = [("unpaired", .unpaired), ("locked", .locked), ("denied", .denied),
                                                 ("notFound", .notFound), ("badRequest", .badRequest),
                                                 ("internal", .internal), ("somethingNew", .internal)]
        for (raw, code) in codes {
            do {
                _ = try reply(VaultLogins.self, #"{"id":7,"error":{"code":"\#(raw)","message":"human readable"}}"#)
                preconditionFailure("error envelope decoded as a result")
            } catch let error as VaultClientError {
                precondition(error == .server(code, "human readable"), raw)
            }
        }
        for (raw, code) in [("locked", VaultErrorCode.locked), ("denied", .denied), ("notFound", .notFound)] {
            do {
                _ = try reply(VaultCode.self, #"{"id":14,"error":{"code":"\#(raw)","message":"human readable"}}"#)
                preconditionFailure("code error envelope decoded as a result")
            } catch let error as VaultClientError {
                precondition(error == .server(code, "human readable"), raw)
            }
        }
        for broken in [#"{"id":14,"result":{"code":"012345"}}"#, #"{"id":14,"result":{"code":12345,"remaining":17}}"#] {
            do {
                _ = try reply(VaultCode.self, broken)
                preconditionFailure("malformed code reply accepted: \(broken)")
            } catch let error as VaultClientError {
                precondition(error == .malformedResponse, broken)
            }
        }
        for broken in [#"{"id":7}"#, #"{"id":7,"result":{"logins":"x"}}"#, "[]", "{"] {
            do {
                _ = try reply(VaultLogins.self, broken)
                preconditionFailure("malformed reply accepted: \(broken)")
            } catch let error as VaultClientError {
                precondition(error == .malformedResponse, broken)
            }
        }

        // Status line, from hello or from the error that stopped it.
        precondition(VaultStatus(hello) == .locked)
        precondition(VaultStatus(try! reply(VaultHello.self, #"{"id":1,"result":{"vault":"Pawl Vault","version":1,"paired":false,"unlocked":true}}"#)) == .notTeamSigned)
        precondition(VaultStatus(try! reply(VaultHello.self, #"{"id":1,"result":{"vault":"Pawl Vault","version":1,"paired":true,"unlocked":true}}"#)) == .connected)
        precondition(VaultStatus(VaultClientError.notRunning) == .notRunning)
        precondition(VaultStatus(VaultClientError.timeout) == .notRunning)
        precondition(VaultStatus(VaultClientError.notPawlVault) == .notPawlVault)
        precondition(VaultStatus(VaultClientError.server(.unpaired, "")) == .notTeamSigned)
        precondition(VaultStatus(VaultClientError.server(.locked, "")) == .locked)

        // Vault errors as DOMException names. Only an excluded credential on create differs.
        let notAllowed: [VaultClientError] = [.server(.denied, "Touch ID cancelled"), .server(.locked, ""),
                                              .server(.unpaired, ""), .server(.notFound, ""), .server(.badRequest, ""),
                                              .server(.internal, ""), .notRunning, .notPawlVault, .timeout,
                                              .connectionClosed, .malformedResponse]
        for error in notAllowed {
            precondition(WebAuthnError(error, creating: false) == .notAllowed && WebAuthnError(error, creating: true) == .notAllowed, "\(error)")
        }
        precondition(WebAuthnError(.server(.denied, "excluded"), creating: true) == .invalidState)
        precondition(WebAuthnError(.server(.denied, "excluded"), creating: false) == .notAllowed)
        precondition(WebAuthnError.notAllowed.rawValue == "NotAllowedError")
        precondition(WebAuthnError.security.rawValue == "SecurityError")
        precondition(WebAuthnError.invalidState.rawValue == "InvalidStateError")
        precondition(WebAuthnError.abort.rawValue == "AbortError")
        precondition(WebAuthnError.notSupported.rawValue == "NotSupportedError")

        print("VaultMessagesCheck passed")
    }
}
