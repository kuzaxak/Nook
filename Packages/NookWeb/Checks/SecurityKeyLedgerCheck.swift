// Licensed under GPL-3.0. See LICENSE.
//
//  SecurityKeyLedgerCheck.swift
//  Nook
//
//  The passkey requests one page has open: keyed by the frame's origin and the shim's random
//  id, so frames cannot collide or end each other's requests; at most one security key request
//  at a time; a vault disconnect ends only vault requests. Run from the repository root:
//
//    swiftc -parse-as-library Packages/NookWeb/Sources/NookWeb/Vault/PasskeyLedger.swift \
//           Packages/NookWeb/Checks/SecurityKeyLedgerCheck.swift -o /tmp/sk-ledger && /tmp/sk-ledger
//

import Foundation

@main
struct SecurityKeyLedgerCheck {
    static func key(_ origin: String, _ byte: Character) -> PasskeyRequestKey {
        PasskeyRequestKey(origin: origin, token: String(repeating: byte, count: 32))!
    }

    static func main() {
        // Ids are the shim's 128-bit random tokens: 32 lowercase hex digits and nothing else.
        precondition(PasskeyRequestKey(origin: "https://a.com", token: "0123456789abcdef0123456789abcdef") != nil)
        for bad in ["", "1", "0123456789ABCDEF0123456789ABCDEF", "0123456789abcdef0123456789abcde", "0123456789abcdef0123456789abcdef0",
                    "0123456789abcdeg0123456789abcdef", " 123456789abcdef0123456789abcdef"] {
            precondition(PasskeyRequestKey(origin: "https://a.com", token: bad) == nil, bad)
        }

        var ledger = PasskeyLedger<String>()
        let a = "https://a.com"
        // Vault requests: as many as the page makes, one per key.
        precondition(ledger.admit(key(a, "1"), kind: .vault, reply: "vault 1") == nil)
        precondition(ledger.admit(key(a, "2"), kind: .vault, reply: "vault 2") == nil)
        precondition(ledger.admit(key(a, "1"), kind: .vault, reply: "again") == .duplicate)
        precondition(ledger.reply(for: key(a, "1")) == "vault 1")

        // The same id from another origin is another request; it cannot reach this one.
        precondition(ledger.admit(key("https://b.com", "1"), kind: .vault, reply: "other frame") == nil)
        precondition(ledger.remove(key("https://b.com", "1")) == "other frame" && ledger.reply(for: key(a, "1")) == "vault 1")

        // One security key request at a time, whichever frame asks; vault requests go on.
        precondition(ledger.admit(key(a, "3"), kind: .securityKey, reply: "key 3") == nil)
        precondition(ledger.securityKeyRequest == key(a, "3"))
        precondition(ledger.admit(key(a, "4"), kind: .securityKey, reply: "key 4") == .busy)
        precondition(ledger.admit(key("https://b.com", "4"), kind: .securityKey, reply: "key 4") == .busy)
        precondition(ledger.reply(for: key(a, "4")) == nil)
        precondition(ledger.admit(key(a, "5"), kind: .vault, reply: "vault 5") == nil)

        // The vault going away ends its requests and leaves the security key request alone.
        precondition(Set(ledger.removeVault()) == ["vault 1", "vault 2", "vault 5"])
        precondition(ledger.reply(for: key(a, "3")) == "key 3" && ledger.securityKeyRequest == key(a, "3"))

        // Only the request that holds the slot frees it.
        ledger.securityKeyEnded(key(a, "9"))
        precondition(ledger.admit(key(a, "6"), kind: .securityKey, reply: "key 6") == .busy)
        ledger.securityKeyEnded(key(a, "3"))
        precondition(ledger.securityKeyRequest == nil && ledger.admit(key(a, "6"), kind: .securityKey, reply: "key 6") == nil)

        // Choosing Pawl Vault on the sheet makes it a vault request and frees the slot.
        ledger.becameVault(key(a, "6"))
        precondition(ledger.securityKeyRequest == nil && ledger.removeVault().contains("key 6"))

        // Answered requests drop out; a new document ends everything.
        precondition(ledger.admit(key(a, "7"), kind: .securityKey, reply: "key 7") == nil)
        precondition(ledger.admit(key(a, "8"), kind: .vault, reply: "answered") == nil)
        ledger.prune { !["answered", "key 3"].contains($0) }
        precondition(ledger.reply(for: key(a, "8")) == nil)
        precondition(ledger.removeAll() == ["key 7"] && ledger.securityKeyRequest == nil)
        precondition(ledger.admit(key(a, "7"), kind: .securityKey, reply: "key 7 again") == nil)
        ledger.prune { $0 != "key 7 again" }
        precondition(ledger.securityKeyRequest == nil && ledger.admit(key(a, "a"), kind: .securityKey, reply: "key a") == nil)

        print("SecurityKeyLedgerCheck passed")
    }
}
