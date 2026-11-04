// Licensed under GPL-3.0. See LICENSE.
//
//  SecurityKeyCeremony.swift
//  Nook
//
//  One WebAuthn create or get against USB security keys. With several keys plugged in, all of
//  them wait for a touch and the first one touched is used; the others get CANCEL. A PIN is
//  asked for when the request or the key needs user verification, through PIN/UV auth protocol
//  two when the key offers it. Replies are checked against the rpId before they go anywhere.
//  One ceremony runs at a time; cancel, the page's timeout and unplugging end it.
//

import CryptoKit
import Foundation

public enum SecurityKeyFailure: Error, Equatable {
    /// GetAssertion found none of the site's credentials on the key.
    case notRegistered
    /// One of `excludeCredentials` is on the key.
    case alreadyRegistered
    case pinBlocked
    /// Three wrong PINs in a row; the key wants to be unplugged first.
    case pinAuthBlocked
    /// The site needs user verification and the key has no PIN.
    case pinRequired
    case residentKeyUnsupported
    /// No FIDO2 (CTAP2) support, such as a U2F-only key.
    case unsupported
    case unsupportedAlgorithm
    case storageFull
    case removed
    case failed

    public var error: WebAuthnError {
        switch self {
        case .alreadyRegistered: return .invalidState
        case .unsupportedAlgorithm: return .notSupported
        default: return .notAllowed
        }
    }
}

public struct SecurityKeyPINPrompt: Equatable {
    public let retries: Int?
    public let wrongPIN: Bool
    public let minimumLength: Int
}

public struct SecurityKeyAccount: Equatable, Identifiable {
    public let id: Int
    public let name: String
    public let displayName: String
}

public enum SecurityKeyStep: Equatable {
    /// Pawl Vault or a security key, before either starts.
    case choose
    case insert
    case touch(several: Bool)
    case pin(SecurityKeyPINPrompt)
    case accounts([SecurityKeyAccount])
    case failed(SecurityKeyFailure)
}

/// A PIN as UTF-8 bytes, overwritten by `wipe()` once it has been hashed.
public final class SecurityKeyPIN {
    public private(set) var bytes: Data

    public init(_ text: String) {
        bytes = Data(text.precomposedStringWithCanonicalMapping.utf8)
    }

    public func wipe() {
        zeroize(&bytes)
        bytes = Data()
    }
}

public enum SecurityKeyAnswer {
    case vault
    case securityKey
    case pin(SecurityKeyPIN)
    case account(Int)
    case dismissed
}

/// The person at the screen, as a ceremony needs them.
@MainActor
public protocol SecurityKeyUser: AnyObject {
    /// A step that waits on the key: insert or touch.
    func show(_ step: SecurityKeyStep)
    /// A step that waits on the user; nil when they cancel or `interrupt()` ends it.
    func ask(_ step: SecurityKeyStep) async -> SecurityKeyAnswer?
    /// Ends a pending `ask` with nil.
    func interrupt()
}

@MainActor
public final class SecurityKeyCeremony {
    public enum Request {
        case create(SecurityKeyCreateRequest)
        case get(SecurityKeyGetRequest)

        var timeout: Duration {
            switch self {
            case .create(let request): return request.timeout
            case .get(let request): return request.timeout
            }
        }
    }

    public enum Outcome: Equatable {
        case created(SecurityKeyCreated)
        case asserted(SecurityKeyAsserted)
    }

    private struct Stopped: Error {}

    @MainActor
    private final class Key {
        let channel: CTAPHIDChannel
        var info: CTAP2.Info?

        init(_ device: SecurityKeyHID) {
            channel = CTAPHIDChannel(device: device)
        }

        func connect() async throws {
            do {
                try await channel.open()
            } catch CTAPHIDChannel.Failure.noCBOR {
                throw SecurityKeyFailure.unsupported
            }
            let (status, reply) = try await channel.cbor(.getInfo, nil, keepalive: nil)
            guard status == CTAP2.Status.ok, let reply, let info = try? CTAP2.Info(reply), info.supportsFIDO2
            else { throw SecurityKeyFailure.unsupported }
            self.info = info
        }

        func send(_ command: CTAP2.Command, _ parameters: CBOR?) async throws -> CBOR? {
            let (status, reply) = try await channel.cbor(command, parameters, keepalive: nil)
            guard status == CTAP2.Status.ok else { throw CTAP2.Failure(status: status) }
            return reply
        }
    }

    private final class PinToken {
        let pinProtocol: PinUvAuthProtocol
        var token: Data

        init(_ pinProtocol: PinUvAuthProtocol, _ token: Data) {
            self.pinProtocol = pinProtocol
            self.token = token
        }

        func auth(_ clientDataHash: Data) -> CTAP2.PinUvAuth {
            CTAP2.PinUvAuth(parameter: pinProtocol.authenticate(key: token, message: clientDataHash),
                            protocolVersion: pinProtocol.version)
        }
    }

    public private(set) static var isRunning = false

    private let request: Request
    private let source: SecurityKeyHIDSource
    private let user: SecurityKeyUser
    private var stopped = false
    private var keyRemoved = false
    private var keys: [Key] = []
    private var candidates: [Key] = []
    private var pinToken: PinToken?
    /// Until a key is chosen: devices found or plugged in that have not been looked at yet.
    private var choosing = false
    private var queued: [SecurityKeyHID] = []
    private var arrivalWaiter: CheckedContinuation<SecurityKeyHID?, Never>?
    private var selectionWaiter: CheckedContinuation<Key?, Never>?

    public init(_ request: Request, source: SecurityKeyHIDSource, user: SecurityKeyUser) {
        self.request = request
        self.source = source
        self.user = user
    }

    /// Runs to the end. A failure the user should read is shown until they dismiss it; cancel
    /// and timeout end without one.
    public func run() async -> Result<Outcome, WebAuthnError> {
        guard !Self.isRunning else { return .failure(.notAllowed) }
        Self.isRunning = true
        let limit = request.timeout
        let timer = Task { [weak self] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled else { return }
            self?.cancel()
        }
        let result = await perform()
        timer.cancel()
        source.stop()
        keys.forEach { $0.channel.close() }
        keys = []
        if let pinToken { zeroize(&pinToken.token) }
        pinToken = nil
        Self.isRunning = false
        return result
    }

    /// The user cancelled, the page aborted or went away, or the timeout passed.
    public func cancel() {
        guard !stopped else { return }
        stopped = true
        keys.forEach { $0.channel.cancel() }
        arrivalWaiter?.resume(returning: nil)
        arrivalWaiter = nil
        selectionWaiter?.resume(returning: nil)
        selectionWaiter = nil
        user.interrupt()
    }

    private func perform() async -> Result<Outcome, WebAuthnError> {
        do {
            let key = try await chooseKey()
            key.channel.onRemoved = { [weak self] in
                self?.keyRemoved = true
                self?.user.interrupt()
            }
            guard !key.channel.isRemoved else { throw SecurityKeyFailure.removed }
            switch request {
            case .create(let request): return .success(.created(try await create(request, on: key)))
            case .get(let request): return .success(.asserted(try await get(request, on: key)))
            }
        } catch {
            if stopped { return .failure(.notAllowed) }
            let failure = failure(for: error)
            _ = await user.ask(.failed(failure))
            return .failure(failure.error)
        }
    }

    private func failure(for error: Error) -> SecurityKeyFailure {
        if keyRemoved { return .removed }
        if let failure = error as? SecurityKeyFailure { return failure }
        switch (error as? CTAP2.Failure)?.status {
        case CTAP2.Status.credentialExcluded: return .alreadyRegistered
        case CTAP2.Status.noCredentials: return .notRegistered
        case CTAP2.Status.unsupportedAlgorithm: return .unsupportedAlgorithm
        case CTAP2.Status.keyStoreFull: return .storageFull
        case CTAP2.Status.pinBlocked: return .pinBlocked
        case CTAP2.Status.pinAuthBlocked: return .pinAuthBlocked
        case CTAP2.Status.pinNotSet: return .pinRequired
        default: break
        }
        return (error as? CTAPHIDChannel.Failure) == .removed ? .removed : .failed
    }

    private func checkStopped() throws {
        if keyRemoved { throw SecurityKeyFailure.removed }
        if stopped { throw Stopped() }
    }

    /// What a nil answer means: the key went away, or the user or page ended the ceremony.
    private func unanswered() -> Error {
        if keyRemoved { return SecurityKeyFailure.removed }
        cancel()
        return Stopped()
    }

    // MARK: - Choosing a key

    private func chooseKey() async throws -> Key {
        var usable: [Key] = []
        var sawUnsupported = false
        choosing = true
        queued = source.start(arrived: { [weak self] device in self?.arrived(device) })
        defer {
            choosing = false
            queued = []
        }
        while true {
            while !queued.isEmpty {
                let key = Key(queued.removeFirst())
                keys.append(key)
                do {
                    try await key.connect()
                    usable.append(key)
                } catch {
                    sawUnsupported = sawUnsupported || (error as? SecurityKeyFailure) == .unsupported
                }
                try checkStopped()
            }
            usable.removeAll { $0.channel.isRemoved }
            if usable.count == 1 { return usable[0] }
            if usable.count > 1 {
                user.show(.touch(several: true))
                if let key = await select(among: usable) { return key }
                try checkStopped()
                usable = []
                continue
            }
            if sawUnsupported { throw SecurityKeyFailure.unsupported }
            try checkStopped()
            user.show(.insert)
            guard let device = await withCheckedContinuation({ arrivalWaiter = $0 }) else { throw Stopped() }
            queued.append(device)
        }
    }

    private func arrived(_ device: SecurityKeyHID) {
        guard choosing else { return }
        if let waiter = arrivalWaiter {
            arrivalWaiter = nil
            return waiter.resume(returning: device)
        }
        guard selectionWaiter != nil else { return queued.append(device) }
        let key = Key(device)
        keys.append(key)
        Task {
            guard (try? await key.connect()) != nil, selectionWaiter != nil else { return }
            candidates.append(key)
            startSelection(key)
        }
    }

    private func select(among usable: [Key]) async -> Key? {
        guard !stopped else { return nil }
        return await withCheckedContinuation { continuation in
            selectionWaiter = continuation
            candidates = usable
            usable.forEach(startSelection)
        }
    }

    private func startSelection(_ key: Key) {
        Task {
            let touched = await touchToSelect(key)
            guard let waiter = selectionWaiter else { return }
            if touched {
                selectionWaiter = nil
                candidates.filter { $0 !== key }.forEach { $0.channel.cancel() }
                candidates = []
                waiter.resume(returning: key)
            } else {
                candidates.removeAll { $0 === key }
                if candidates.isEmpty {
                    selectionWaiter = nil
                    waiter.resume(returning: nil)
                }
            }
        }
    }

    /// Waits for a touch: authenticatorSelection on CTAP 2.1 keys; on older ones a
    /// MakeCredential with an empty pinUvAuthParam (PIN keys) or for a throwaway relying party.
    private func touchToSelect(_ key: Key) async -> Bool {
        guard let info = key.info else { return false }
        let command: CTAP2.Command
        var parameters: CBOR?
        if info.supportsSelection {
            command = .selection
        } else {
            command = .makeCredential
            parameters = CTAP2.makeCredential(
                clientDataHash: Data(count: 32), rp: (".dummy", ""), user: (Data([0]), "dummy", ""),
                algorithms: [-7], excludeList: [], residentKey: false,
                auth: info.supportsPIN ? CTAP2.PinUvAuth(parameter: Data(), protocolVersion: 1) : nil)
        }
        while true {
            guard let (status, _) = try? await key.channel.cbor(command, parameters, keepalive: nil) else { return false }
            switch status {
            case CTAP2.Status.ok, CTAP2.Status.pinInvalid, CTAP2.Status.pinNotSet, CTAP2.Status.pinAuthInvalid:
                return true
            case CTAP2.Status.userActionTimeout, CTAP2.Status.actionTimeout:
                continue
            default:
                return false
            }
        }
    }

    // MARK: - User verification

    private func needsUserVerification(_ requirement: SecurityKeyRequirement, _ info: CTAP2.Info,
                                       creatingResidentKey residentKey: Bool?) throws -> Bool {
        var needed: Bool
        switch requirement {
        case .required: needed = true
        case .preferred: needed = info.hasPIN
        case .discouraged: needed = false
        }
        if info.alwaysUV { needed = true }
        if let residentKey, info.hasPIN, residentKey || !info.makeCredentialWithoutUV { needed = true }
        if needed, !info.hasPIN {
            if requirement == .required || info.alwaysUV { throw SecurityKeyFailure.pinRequired }
            needed = false
        }
        return needed
    }

    private func obtainPinToken(_ key: Key, _ info: CTAP2.Info, permissions: CTAP2.Permissions, rpId: String) async throws -> PinToken {
        guard let pinProtocol = PinUvAuthProtocol.preferred(from: info.pinUvAuthProtocols) else { throw SecurityKeyFailure.unsupported }
        var wrongPIN = false
        while true {
            let retries = try await key.send(.clientPIN, CTAP2.clientPIN(CTAP2.ClientPIN.getRetries, protocolVersion: pinProtocol.version))?[3]?.int
            if retries == 0 { throw SecurityKeyFailure.pinBlocked }
            let answer = await user.ask(.pin(SecurityKeyPINPrompt(retries: retries, wrongPIN: wrongPIN, minimumLength: info.minPINLength)))
            guard case .pin(let pin)? = answer else { throw unanswered() }
            defer { pin.wipe() }
            try checkStopped()
            guard (info.minPINLength...63).contains(pin.bytes.count) else { continue }

            guard let peer = try await key.send(.clientPIN, CTAP2.clientPIN(CTAP2.ClientPIN.getKeyAgreement, protocolVersion: pinProtocol.version))?[1]
            else { throw CTAP2.Malformed() }
            var (keyAgreement, sharedSecret) = try pinProtocol.encapsulate(peer: peer)
            defer { zeroize(&sharedSecret) }
            var pinHash = PinUvAuthProtocol.pinHash(pin.bytes)
            defer { zeroize(&pinHash) }
            pin.wipe()
            let pinHashEnc = try pinProtocol.encrypt(key: sharedSecret, plaintext: pinHash)
            let parameters = info.supportsPermissions
                ? CTAP2.clientPIN(CTAP2.ClientPIN.getPinUvAuthTokenUsingPinWithPermissions, protocolVersion: pinProtocol.version,
                                  keyAgreement: keyAgreement, pinHashEnc: pinHashEnc, permissions: permissions, rpId: rpId)
                : CTAP2.clientPIN(CTAP2.ClientPIN.getPinToken, protocolVersion: pinProtocol.version,
                                  keyAgreement: keyAgreement, pinHashEnc: pinHashEnc)
            let (status, reply) = try await key.channel.cbor(.clientPIN, parameters, keepalive: nil)
            try checkStopped()
            switch status {
            case CTAP2.Status.ok:
                guard let encrypted = reply?[2]?.bytes else { throw CTAP2.Malformed() }
                let token = try pinProtocol.decrypt(key: sharedSecret, ciphertext: encrypted)
                guard pinProtocol.version == 2 ? token.count == 32 : [16, 32].contains(token.count) else { throw CTAP2.Malformed() }
                let result = PinToken(pinProtocol, token)
                pinToken = result
                return result
            case CTAP2.Status.pinInvalid, CTAP2.Status.pinPolicyViolation:
                wrongPIN = true
            default:
                throw CTAP2.Failure(status: status)
            }
        }
    }

    /// The credentials of `list` the key holds for `rpId`, probed without user presence in
    /// batches the key accepts: the first batch with a match, narrowed to it when the key says which.
    private func firstMatch(_ list: [Data], rpId: String, on key: Key, batch: Int) async throws -> [Data]? {
        for start in stride(from: 0, to: list.count, by: batch) {
            let chunk = Array(list[start..<min(start + batch, list.count)])
            let probe = CTAP2.getAssertion(rpId: rpId, clientDataHash: Data(count: 32), allowList: chunk, userPresence: false, auth: nil)
            let (status, reply) = try await key.channel.cbor(.getAssertion, probe, keepalive: nil)
            try checkStopped()
            switch status {
            case CTAP2.Status.ok:
                let found = reply.flatMap { try? CTAP2.Assertion($0) }?.credentialID
                return found.map { chunk.contains($0) ? [$0] : chunk } ?? chunk
            case CTAP2.Status.noCredentials:
                continue
            default:
                throw CTAP2.Failure(status: status)
            }
        }
        return nil
    }

    private static func usable(_ list: [Data], _ info: CTAP2.Info) -> [Data] {
        guard let longest = info.maxCredentialIdLength else { return list }
        return list.filter { $0.count <= longest }
    }

    /// Sends `parameters` until the key answers something other than a touch timeout; a PIN
    /// demanded by the key is asked for once and the request rebuilt with its token.
    private func touchRequest(_ command: CTAP2.Command, on key: Key, _ info: CTAP2.Info, permissions: CTAP2.Permissions,
                              rpId: String, token: inout PinToken?, parameters: (PinToken?) -> CBOR) async throws -> CBOR? {
        while true {
            user.show(.touch(several: false))
            let (status, reply) = try await key.channel.cbor(command, parameters(token), keepalive: nil)
            try checkStopped()
            switch status {
            case CTAP2.Status.ok:
                return reply
            case CTAP2.Status.pinRequired where token == nil && info.hasPIN:
                token = try await obtainPinToken(key, info, permissions: permissions, rpId: rpId)
            case CTAP2.Status.userActionTimeout, CTAP2.Status.actionTimeout:
                continue
            default:
                throw CTAP2.Failure(status: status)
            }
        }
    }

    // MARK: - Create

    private func create(_ request: SecurityKeyCreateRequest, on key: Key) async throws -> SecurityKeyCreated {
        guard let info = key.info else { throw SecurityKeyFailure.unsupported }
        let residentKey: Bool
        switch request.residentKey {
        case .required:
            guard info.supportsResidentKeys else { throw SecurityKeyFailure.residentKeyUnsupported }
            residentKey = true
        case .preferred: residentKey = info.supportsResidentKeys
        case .discouraged: residentKey = false
        }
        let verify = try needsUserVerification(request.userVerification, info, creatingResidentKey: residentKey)
        var exclude = Self.usable(request.excludeList, info)
        if let batch = info.maxCredentialCountInList, exclude.count > batch {
            exclude = try await firstMatch(exclude, rpId: request.rpId, on: key, batch: batch) ?? []
        }
        var token = verify ? try await obtainPinToken(key, info, permissions: .makeCredential, rpId: request.rpId) : nil
        let hash = request.clientDataHash
        let reply = try await touchRequest(.makeCredential, on: key, info, permissions: .makeCredential, rpId: request.rpId,
                                           token: &token) { token in
            CTAP2.makeCredential(
                clientDataHash: hash, rp: (request.rpId, request.rpName),
                user: (request.userID, request.userName, request.userDisplayName), algorithms: request.algorithms,
                excludeList: exclude, residentKey: residentKey, auth: token?.auth(hash))
        }
        guard let reply, let attestation = try? CTAP2.Attestation(reply),
              let data = try? AuthenticatorData(attestation.authenticatorData),
              let credential = data.attestedCredential,
              let algorithm = COSEKey.algorithm(credential.publicKey), request.algorithms.contains(algorithm),
              data.belongs(to: request.rpId), data.userPresent,
              data.userVerified || (token == nil && request.userVerification != .required)
        else { throw SecurityKeyFailure.failed }
        let anonymized = data.anonymized
        return SecurityKeyCreated(
            credentialID: credential.credentialID, authenticatorData: anonymized,
            attestationObject: AuthenticatorData.noneAttestationObject(anonymized), publicKeyAlgorithm: algorithm,
            publicKey: COSEKey.subjectPublicKeyInfo(credential.publicKey), residentKey: residentKey)
    }

    // MARK: - Get

    private func get(_ request: SecurityKeyGetRequest, on key: Key) async throws -> SecurityKeyAsserted {
        guard let info = key.info else { throw SecurityKeyFailure.unsupported }
        var allow = Self.usable(request.allowList, info)
        if !request.allowList.isEmpty, allow.isEmpty { throw SecurityKeyFailure.notRegistered }
        let verify = try needsUserVerification(request.userVerification, info, creatingResidentKey: nil)
        if let batch = info.maxCredentialCountInList, allow.count > batch {
            guard let match = try await firstMatch(allow, rpId: request.rpId, on: key, batch: batch) else {
                throw SecurityKeyFailure.notRegistered
            }
            allow = match
        }
        var token = verify ? try await obtainPinToken(key, info, permissions: .getAssertion, rpId: request.rpId) : nil
        let hash = request.clientDataHash
        let allowList = allow
        let reply = try await touchRequest(.getAssertion, on: key, info, permissions: .getAssertion, rpId: request.rpId,
                                           token: &token) { token in
            CTAP2.getAssertion(rpId: request.rpId, clientDataHash: hash, allowList: allowList, userPresence: true,
                               auth: token?.auth(hash))
        }
        guard let reply, let first = try? CTAP2.Assertion(reply) else { throw SecurityKeyFailure.failed }

        var assertions = [first]
        for _ in 1..<min(max(first.numberOfCredentials ?? 1, 1), 100) {
            guard let next = try await key.send(.getNextAssertion, nil), let assertion = try? CTAP2.Assertion(next)
            else { throw SecurityKeyFailure.failed }
            assertions.append(assertion)
        }
        var chosen = first
        if assertions.count > 1 {
            let accounts = assertions.enumerated().map { index, assertion in
                SecurityKeyAccount(id: index, name: VaultPrompt.displayText(assertion.userName ?? ""),
                                   displayName: VaultPrompt.displayText(assertion.userDisplayName ?? ""))
            }
            guard case .account(let index)? = await user.ask(.accounts(accounts)) else { throw unanswered() }
            try checkStopped()
            guard assertions.indices.contains(index) else { throw unanswered() }
            chosen = assertions[index]
        }

        guard let data = try? AuthenticatorData(chosen.authenticatorData), data.belongs(to: request.rpId), data.userPresent,
              data.userVerified || (token == nil && request.userVerification != .required),
              let credentialID = chosen.credentialID ?? (allowList.count == 1 ? allowList[0] : nil),
              allowList.isEmpty || allowList.contains(credentialID)
        else { throw SecurityKeyFailure.failed }
        return SecurityKeyAsserted(credentialID: credentialID, authenticatorData: chosen.authenticatorData,
                                   signature: chosen.signature, userHandle: chosen.userID)
    }
}
