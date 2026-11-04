// Licensed under GPL-3.0. See LICENSE.
//
//  PasskeyLedger.swift
//  Nook
//
//  The passkey requests one page has open. Every frame runs its own shim, so a request is
//  known by its frame's origin (from WebKit) and the 128-bit random id its shim gave it: no
//  frame can collide with another or end another's request. Pawl Vault requests run side by
//  side; a security key request, or the sheet choosing between the two, is one at a time.
//

import Foundation

public struct PasskeyRequestKey: Hashable {
    public let origin: String
    public let token: String

    /// Nil unless `token` is 32 lowercase hex digits, as the shim makes them.
    public init?(origin: String, token: String) {
        let digits = Set("0123456789abcdef".utf8)
        guard token.utf8.count == 32, token.utf8.allSatisfy(digits.contains) else { return nil }
        self.origin = origin
        self.token = token
    }
}

public struct PasskeyLedger<Reply> {
    public enum Kind {
        case vault
        /// A security key ceremony, or the sheet asking whether to use one.
        case securityKey
    }

    public enum Refusal: Equatable {
        case duplicate
        /// Another security key request is open on this page.
        case busy
    }

    private var entries: [PasskeyRequestKey: (kind: Kind, reply: Reply)] = [:]
    public private(set) var securityKeyRequest: PasskeyRequestKey?

    public init() {}

    public mutating func admit(_ key: PasskeyRequestKey, kind: Kind, reply: Reply) -> Refusal? {
        guard entries[key] == nil else { return .duplicate }
        if kind == .securityKey {
            guard securityKeyRequest == nil else { return .busy }
            securityKeyRequest = key
        }
        entries[key] = (kind, reply)
        return nil
    }

    public func reply(for key: PasskeyRequestKey) -> Reply? {
        entries[key]?.reply
    }

    public mutating func remove(_ key: PasskeyRequestKey) -> Reply? {
        if securityKeyRequest == key { securityKeyRequest = nil }
        return entries.removeValue(forKey: key)?.reply
    }

    /// The security key request is over; its slot opens.
    public mutating func securityKeyEnded(_ key: PasskeyRequestKey) {
        guard securityKeyRequest == key else { return }
        securityKeyRequest = nil
    }

    /// The user chose Pawl Vault on the sheet.
    public mutating func becameVault(_ key: PasskeyRequestKey) {
        securityKeyEnded(key)
        if let entry = entries[key] { entries[key] = (.vault, entry.reply) }
    }

    /// Drops the requests `isOpen` says were answered; an answered security key request frees its slot.
    public mutating func prune(_ isOpen: (Reply) -> Bool) {
        entries = entries.filter { isOpen($0.value.reply) }
        if let key = securityKeyRequest, entries[key] == nil { securityKeyRequest = nil }
    }

    /// The vault disconnected: its requests end.
    public mutating func removeVault() -> [Reply] {
        let vault = entries.filter { $0.value.kind == .vault }
        vault.keys.forEach { entries.removeValue(forKey: $0) }
        return vault.values.map(\.reply)
    }

    /// Passkeys are off, or the document is gone: every request ends.
    public mutating func removeAll() -> [Reply] {
        let all = entries.values.map(\.reply)
        entries = [:]
        securityKeyRequest = nil
        return all
    }
}
