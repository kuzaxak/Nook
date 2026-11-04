// Licensed under GPL-3.0. See LICENSE.
//
//  SecurityKeyCeremonyCheck.swift
//  Nook
//
//  Whole create and get ceremonies against a fake CTAP2 authenticator behind a fake HID
//  device: CTAPHID framing, keepalives, PIN protocols two and one with wrong and blocked PINs,
//  excludeCredentials, several accounts, batched credential lists, a key that demands a PIN,
//  cancel, timeout, unplugging, no key plugged in, several keys, two ceremonies at once, a
//  U2F-only key, and a key that answers for another site. Run from the repository root:
//
//    swiftc -parse-as-library \
//      Packages/NookWeb/Sources/NookWeb/SecurityKey/*.swift \
//      Packages/NookWeb/Sources/NookWeb/Vault/{Base64URL,PublicSuffixList,VaultMessages,VaultPrompt,WebAuthnClientData,WebAuthnError,WebAuthnPolicy}.swift \
//      Packages/NookWeb/Checks/SecurityKeyCeremonyCheck.swift -o /tmp/sk-ceremony && /tmp/sk-ceremony
//

import CryptoKit
import Foundation

// MARK: - Fake authenticator

struct FakeCredential {
    let id: Data
    let rpId: String
    let userID: Data
    let userName: String
    let key: P256.Signing.PrivateKey
    let residentKey: Bool
}

@MainActor
final class FakeKey: SecurityKeyHID {
    var onInput: ((Data?) -> Void)?
    var versions = ["FIDO_2_0", "FIDO_2_1"]
    var pinProtocols = [2, 1]
    var pin: String?
    var retries = 8
    var maxCredentialCountInList: Int?
    var u2fOnly = false
    var requirePINForAssertion = false
    var answersForRP: String?
    var autoTouch = true
    var keepalivesBeforeTouch = 0
    var minPINLength: Int?
    var credentials: [FakeCredential] = []
    var onWaitingForTouch: (() -> Void)?
    /// What the key was asked, in order, without secrets.
    private(set) var log: [String] = []
    private(set) var lastClientDataHash: Data?
    let aaguid = Data(repeating: 0xa5, count: 16)

    private var assemblers: [UInt32: CTAPHID.Assembler] = [:]
    private var nextChannel: UInt32 = 0x0100_0000
    private var agreement = P256.KeyAgreement.PrivateKey()
    private var token: Data?
    private var wrongInARow = 0
    private var touchWaiter: (UInt32, () -> Void)?
    private var queuedAssertions: [CBOR] = []
    private var counter: UInt32 = 0

    var hasPIN: Bool { pin != nil }

    func write(_ report: Data) -> Bool {
        let channel = report.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        var assembler = assemblers[channel] ?? CTAPHID.Assembler(channel: channel)
        let event = try? assembler.add(report)
        assemblers[channel] = assembler
        guard case .message(let command, let payload)? = event else { return true }
        Task { @MainActor in self.handle(channel: channel, command: command, payload: payload) }
        return true
    }

    func unplug() {
        onInput?(nil)
    }

    func touch() {
        guard let (_, done) = touchWaiter else { return }
        touchWaiter = nil
        done()
    }

    var isWaitingForTouch: Bool { touchWaiter != nil }

    private func send(_ channel: UInt32, _ command: CTAPHID.Command, _ payload: Data) {
        for packet in CTAPHID.packets(channel: channel, command: command, payload: payload)! {
            Task { @MainActor in self.onInput?(packet) }
        }
    }

    private func reply(_ channel: UInt32, _ status: UInt8, _ body: CBOR? = nil) {
        send(channel, .cbor, Data([status]) + (body?.encoded ?? Data()))
    }

    private func waitForTouch(_ channel: UInt32, then done: @escaping () -> Void) {
        touchWaiter = (channel, done)
        for _ in 0..<max(keepalivesBeforeTouch, 1) {
            send(channel, .keepalive, Data([CTAPHID.Keepalive.userPresenceNeeded]))
        }
        onWaitingForTouch?()
        if autoTouch { Task { @MainActor in self.touch() } }
    }

    private func handle(channel: UInt32, command: UInt8, payload: Data) {
        switch command {
        case CTAPHID.Command.initialize.rawValue:
            log.append("init")
            nextChannel += 1
            let capabilities: UInt8 = u2fOnly ? 0x01 : 0x05
            send(CTAPHID.broadcastChannel, .initialize,
                 payload.prefix(8) + Data(CTAPHID.channelBytes(nextChannel)) + Data([2, 5, 4, 3, capabilities]))
        case CTAPHID.Command.cancel.rawValue:
            log.append("cancel")
            if let (waiting, _) = touchWaiter, waiting == channel {
                touchWaiter = nil
                reply(channel, CTAP2.Status.keepaliveCancel)
            }
        case CTAPHID.Command.cbor.rawValue:
            guard let first = payload.first else { return reply(channel, 0x01) }
            let parameters = payload.count > 1 ? try? CBOR.decode(payload.dropFirst()) : nil
            cbor(channel, first, parameters)
        default:
            send(channel, .error, Data([0x01]))
        }
    }

    private func cbor(_ channel: UInt32, _ command: UInt8, _ p: CBOR?) {
        switch command {
        case CTAP2.Command.getInfo.rawValue:
            log.append("getInfo")
            var options: [CBOR: CBOR] = [.text("rk"): .bool(true), .text("up"): .bool(true), .text("clientPin"): .bool(hasPIN)]
            if versions.contains("FIDO_2_1") {
                options[.text("pinUvAuthToken")] = .bool(true)
                options[.text("makeCredUvNotRqd")] = .bool(true)
            }
            var info: [CBOR: CBOR] = [.int(1): .array(versions.map { .text($0) }), .int(3): .bytes(aaguid),
                                      .int(4): .map(options), .int(5): .int(1200), .int(6): .array(pinProtocols.map { .int($0) })]
            if let maxCredentialCountInList { info[.int(7)] = .int(maxCredentialCountInList) }
            if let minPINLength { info[.int(0x0d)] = .int(minPINLength) }
            reply(channel, 0, .map(info))
        case CTAP2.Command.clientPIN.rawValue:
            clientPIN(channel, p!)
        case CTAP2.Command.selection.rawValue:
            log.append("selection")
            waitForTouch(channel) { self.reply(channel, 0) }
        case CTAP2.Command.makeCredential.rawValue:
            makeCredential(channel, p!)
        case CTAP2.Command.getAssertion.rawValue:
            getAssertion(channel, p!)
        case CTAP2.Command.getNextAssertion.rawValue:
            log.append("getNextAssertion")
            guard !queuedAssertions.isEmpty else { return reply(channel, 0x30) }
            reply(channel, 0, queuedAssertions.removeFirst())
        default:
            reply(channel, 0x01)
        }
    }

    private func clientPIN(_ channel: UInt32, _ p: CBOR) {
        let version = p[1]!.int!, sub = p[2]!.int!
        let pinProtocol = PinUvAuthProtocol(version: version)
        switch sub {
        case 1:
            log.append("getRetries")
            reply(channel, 0, .map([.int(3): .int(retries)]))
        case 2:
            log.append("getKeyAgreement:\(version)")
            reply(channel, 0, .map([.int(1): PinUvAuthProtocol.coseKey(agreement.publicKey)]))
        case 5, 9:
            log.append(sub == 5 ? "getPinToken:\(version)" : "getPinUvAuthToken:\(version):\(p[9]?.int ?? -1):\(p[0x0a]?.text ?? "")")
            guard let pin else { return reply(channel, CTAP2.Status.pinNotSet) }
            guard retries > 0 else { return reply(channel, CTAP2.Status.pinBlocked) }
            let shared = try! pinProtocol.encapsulate(peer: p[3]!, privateKey: agreement).sharedSecret
            agreement = P256.KeyAgreement.PrivateKey()
            let sent = try? pinProtocol.decrypt(key: shared, ciphertext: p[6]!.bytes!)
            guard sent == PinUvAuthProtocol.pinHash(Data(pin.utf8)) else {
                retries -= 1
                wrongInARow += 1
                if retries == 0 { return reply(channel, CTAP2.Status.pinBlocked) }
                return reply(channel, wrongInARow >= 3 ? CTAP2.Status.pinAuthBlocked : CTAP2.Status.pinInvalid)
            }
            retries = 8
            wrongInARow = 0
            let fresh = Data((0..<(version == 2 ? 32 : 16)).map { _ in UInt8.random(in: 0...255) })
            token = fresh
            reply(channel, 0, .map([.int(2): .bytes(try! pinProtocol.encrypt(key: shared, plaintext: fresh))]))
        default:
            reply(channel, 0x01)
        }
    }

    /// Nil when the request carries no PIN auth; false when it does not check out.
    private func verifiedPIN(_ p: CBOR, param: Int, version: Int, hash: Data) -> Bool? {
        guard let auth = p[param]?.bytes else { return nil }
        guard let token, let protocolVersion = p[version]?.int else { return false }
        return PinUvAuthProtocol(version: protocolVersion).authenticate(key: token, message: hash) == auth
    }

    private func authData(rpId: String, flags: UInt8, attested: (Data, P256.Signing.PublicKey)? = nil) -> Data {
        counter += 1
        var data = Data(SHA256.hash(data: Data((answersForRP ?? rpId).utf8)))
        data.append(flags | (attested == nil ? 0 : 0x40))
        data.append(contentsOf: [UInt8(counter >> 24), UInt8((counter >> 16) & 0xff), UInt8((counter >> 8) & 0xff), UInt8(counter & 0xff)])
        if let (id, key) = attested {
            let point = key.x963Representation
            data += aaguid + Data([UInt8(id.count >> 8), UInt8(id.count & 0xff)]) + id
            data += CBOR.map([.int(1): .int(2), .int(3): .int(-7), .int(-1): .int(1),
                              .int(-2): .bytes(point.subdata(in: 1..<33)), .int(-3): .bytes(point.subdata(in: 33..<65))]).encoded
        }
        return data
    }

    private func makeCredential(_ channel: UInt32, _ p: CBOR) {
        let hash = p[1]!.bytes!, rpId = p[2]!["id"]!.text!
        let residentKey = p[7]?["rk"]?.bool == true
        if let auth = p[8]?.bytes, auth.isEmpty {
            log.append("makeCredential:selection")
            return waitForTouch(channel) { self.reply(channel, self.hasPIN ? CTAP2.Status.pinInvalid : CTAP2.Status.pinNotSet) }
        }
        log.append("makeCredential:\(rpId):rk=\(residentKey):pin=\(p[8] != nil)")
        lastClientDataHash = hash
        let verified = verifiedPIN(p, param: 8, version: 9, hash: hash)
        if verified == false { return reply(channel, CTAP2.Status.pinAuthInvalid) }
        if verified == nil, hasPIN, residentKey { return reply(channel, CTAP2.Status.pinRequired) }
        let excluded = (p[5]?.array ?? []).compactMap { $0["id"]?.bytes }
        if credentials.contains(where: { $0.rpId == rpId && excluded.contains($0.id) }) {
            return waitForTouch(channel) { self.reply(channel, CTAP2.Status.credentialExcluded) }
        }
        guard (p[4]?.array ?? []).contains(where: { $0["alg"]?.int == -7 }) else {
            return reply(channel, CTAP2.Status.unsupportedAlgorithm)
        }
        waitForTouch(channel) {
            let key = P256.Signing.PrivateKey()
            let id = Data((0..<48).map { _ in UInt8.random(in: 0...255) })
            let user = p[3]!
            self.credentials.append(FakeCredential(id: id, rpId: rpId, userID: user["id"]!.bytes!,
                                                   userName: user["name"]?.text ?? "", key: key, residentKey: residentKey))
            let data = self.authData(rpId: rpId, flags: 0x01 | (verified == true ? 0x04 : 0), attested: (id, key.publicKey))
            let signature = try! key.signature(for: data + hash).derRepresentation
            self.reply(channel, 0, .map([.int(1): .text("packed"), .int(2): .bytes(data),
                                         .int(3): .map([.text("alg"): .int(-7), .text("sig"): .bytes(signature)])]))
        }
    }

    private func assertion(_ credential: FakeCredential, hash: Data, flags: UInt8, total: Int?) -> CBOR {
        let data = authData(rpId: credential.rpId, flags: flags)
        var body: [CBOR: CBOR] = [.int(1): CTAP2.descriptor(credential.id), .int(2): .bytes(data),
                                  .int(3): .bytes(try! credential.key.signature(for: data + hash).derRepresentation)]
        if credential.residentKey {
            body[.int(4)] = flags & 0x04 != 0
                ? .map([.text("id"): .bytes(credential.userID), .text("name"): .text(credential.userName)])
                : .map([.text("id"): .bytes(credential.userID)])
        }
        if let total, total > 1 { body[.int(5)] = .int(total) }
        return .map(body)
    }

    private func getAssertion(_ channel: UInt32, _ p: CBOR) {
        let rpId = p[1]!.text!, hash = p[2]!.bytes!
        let allow = (p[3]?.array ?? []).compactMap { $0["id"]?.bytes }
        let silent = p[5]?["up"]?.bool == false
        log.append(silent ? "probe:\(allow.count)" : "getAssertion:\(rpId):allow=\(allow.count):pin=\(p[6] != nil)")
        if !silent { lastClientDataHash = hash }
        let verified = verifiedPIN(p, param: 6, version: 7, hash: hash)
        if verified == false { return reply(channel, CTAP2.Status.pinAuthInvalid) }
        if verified == nil, requirePINForAssertion, !silent { return reply(channel, CTAP2.Status.pinRequired) }
        let matches = credentials.filter { $0.rpId == rpId && (allow.isEmpty ? $0.residentKey : allow.contains($0.id)) }
        guard let first = matches.first else { return reply(channel, CTAP2.Status.noCredentials) }
        if silent { return reply(channel, 0, assertion(first, hash: hash, flags: 0, total: nil)) }
        let flags: UInt8 = 0x01 | (verified == true ? 0x04 : 0)
        waitForTouch(channel) {
            self.queuedAssertions = matches.dropFirst().map { self.assertion($0, hash: hash, flags: flags, total: nil) }
            self.reply(channel, 0, self.assertion(first, hash: hash, flags: flags, total: allow.isEmpty ? matches.count : nil))
        }
    }
}

@MainActor
final class FakeSource: SecurityKeyHIDSource {
    var present: [FakeKey]
    private var arrived: ((SecurityKeyHID) -> Void)?
    private(set) var stops = 0

    init(_ present: [FakeKey]) {
        self.present = present
    }

    func start(arrived: @escaping (SecurityKeyHID) -> Void) -> [SecurityKeyHID] {
        self.arrived = arrived
        return present
    }

    func stop() {
        arrived = nil
        stops += 1
    }

    func plug(_ key: FakeKey) {
        present.append(key)
        arrived?(key)
    }
}

@MainActor
final class FakeUser: SecurityKeyUser {
    private(set) var steps: [SecurityKeyStep] = []
    var answers: [SecurityKeyAnswer?] = []
    var onStep: ((SecurityKeyStep) -> Void)?
    private var pending: CheckedContinuation<SecurityKeyAnswer?, Never>?

    func show(_ step: SecurityKeyStep) {
        if steps.last != step { steps.append(step) }
        onStep?(step)
    }

    func ask(_ step: SecurityKeyStep) async -> SecurityKeyAnswer? {
        steps.append(step)
        onStep?(step)
        if !answers.isEmpty { return answers.removeFirst() }
        return await withCheckedContinuation { pending = $0 }
    }

    func interrupt() {
        pending?.resume(returning: nil)
        pending = nil
    }
}

@MainActor
final class Journal {
    var lines: [String] = []
}

@MainActor
final class Box {
    var result: Result<SecurityKeyCeremony.Outcome, WebAuthnError>?
}

// MARK: - Check

@main
struct SecurityKeyCeremonyCheck {
    static let origin = "https://login.example.com"
    static let rpId = "example.com"

    static func createRequest(rk: SecurityKeyRequirement = .discouraged, uv: SecurityKeyRequirement = .preferred,
                              exclude: [Data] = [], algorithms: [Int] = [-7, -257], user: String = "alice",
                              timeout: Duration = .seconds(60)) -> SecurityKeyCreateRequest {
        SecurityKeyCreateRequest(
            rpId: rpId, rpName: "Example", userID: Data(user.utf8), userName: user, userDisplayName: user.capitalized,
            clientDataJSON: WebAuthnClientData.json(.create, challenge: Data(0..<32), origin: origin),
            algorithms: algorithms, excludeList: exclude, residentKey: rk, userVerification: uv, credProps: true, timeout: timeout)
    }

    static func getRequest(allow: [Data], uv: SecurityKeyRequirement = .preferred, timeout: Duration = .seconds(60)) -> SecurityKeyGetRequest {
        SecurityKeyGetRequest(rpId: rpId, clientDataJSON: WebAuthnClientData.json(.get, challenge: Data(32..<64), origin: origin),
                              allowList: allow, userVerification: uv, timeout: timeout)
    }

    @MainActor
    static func run(_ request: SecurityKeyCeremony.Request, _ keys: [FakeKey], answers: [SecurityKeyAnswer?] = [],
                    source: FakeSource? = nil, onStep: ((SecurityKeyStep, SecurityKeyCeremony) -> Void)? = nil)
        async -> (Result<SecurityKeyCeremony.Outcome, WebAuthnError>, [SecurityKeyStep]) {
        let user = FakeUser()
        user.answers = answers
        let source = source ?? FakeSource(keys)
        let ceremony = SecurityKeyCeremony(request, source: source, user: user)
        user.onStep = { step in onStep?(step, ceremony) }
        let result = await ceremony.run()
        precondition(source.stops == 1 && !SecurityKeyCeremony.isRunning)
        return (result, user.steps)
    }

    static func created(_ result: Result<SecurityKeyCeremony.Outcome, WebAuthnError>, line: UInt = #line) -> SecurityKeyCreated {
        guard case .success(.created(let credential)) = result else { preconditionFailure("\(result)", line: line) }
        return credential
    }

    static func asserted(_ result: Result<SecurityKeyCeremony.Outcome, WebAuthnError>, line: UInt = #line) -> SecurityKeyAsserted {
        guard case .success(.asserted(let assertion)) = result else { preconditionFailure("\(result)", line: line) }
        return assertion
    }

    static func failed(_ result: Result<SecurityKeyCeremony.Outcome, WebAuthnError>) -> WebAuthnError? {
        if case .failure(let error) = result { return error }
        return nil
    }

    static func pin(_ text: String) -> SecurityKeyAnswer { .pin(SecurityKeyPIN(text)) }

    /// Lets the fake key handle what was written to it last.
    @MainActor
    static func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    static func verify(_ assertion: SecurityKeyAsserted, publicKey: Data?, clientDataJSON: Data) -> Bool {
        guard let publicKey, let key = try? P256.Signing.PublicKey(derRepresentation: publicKey),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: assertion.signature)
        else { return false }
        return key.isValidSignature(signature, for: assertion.authenticatorData + WebAuthnClientData.hash(clientDataJSON))
    }

    @MainActor
    static func main() async {
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 120)
            fatalError("SecurityKeyCeremonyCheck did not finish in two minutes")
        }

        // Register without a PIN, then sign in with that credential.
        let key = FakeKey()
        let create = createRequest()
        let (made, madeSteps) = await run(.create(create), [key])
        let credential = created(made)
        precondition(madeSteps == [.touch(several: false)], "\(madeSteps)")
        precondition(key.log == ["init", "getInfo", "makeCredential:example.com:rk=false:pin=false"], "\(key.log)")
        precondition(key.lastClientDataHash == create.clientDataHash)
        precondition(credential.credentialID == key.credentials[0].id && credential.publicKeyAlgorithm == -7 && !credential.residentKey)
        let data = try! AuthenticatorData(credential.authenticatorData)
        precondition(data.belongs(to: rpId) && data.userPresent && !data.userVerified)
        precondition(data.attestedCredential?.aaguid == Data(count: 16), "AAGUID not cleared")
        let attestationObject = try! CBOR.decode(credential.attestationObject)
        precondition(attestationObject == .map([.text("fmt"): .text("none"), .text("attStmt"): .map([:]),
                                                .text("authData"): .bytes(credential.authenticatorData)]))
        precondition((try? P256.Signing.PublicKey(derRepresentation: credential.publicKey!))?.x963Representation
            == key.credentials[0].key.publicKey.x963Representation)

        let get = getRequest(allow: [Data(repeating: 9, count: 16), credential.credentialID])
        let (signed, signSteps) = await run(.get(get), [key])
        let assertion = asserted(signed)
        precondition(signSteps == [.touch(several: false)])
        precondition(assertion.credentialID == credential.credentialID && assertion.userHandle == nil)
        precondition(key.lastClientDataHash == get.clientDataHash)
        precondition(verify(assertion, publicKey: credential.publicKey, clientDataJSON: get.clientDataJSON))

        // Keepalives while the key waits for a touch.
        let patient = FakeKey()
        patient.keepalivesBeforeTouch = 40
        let patientCredential = created(await run(.create(createRequest()), [patient]).0)
        precondition(patientCredential.credentialID == patient.credentials[0].id)

        // PIN protocol two: a wrong PIN, then the right one; the token carries the mc permission and rpId.
        let locked = FakeKey()
        locked.pin = "1234"
        let (withPIN, pinSteps) = await run(.create(createRequest(rk: .required)), [locked], answers: [pin("0000"), pin("1234")])
        let resident = created(withPIN)
        precondition(resident.residentKey && (try! AuthenticatorData(resident.authenticatorData)).userVerified)
        precondition(pinSteps == [.pin(SecurityKeyPINPrompt(retries: 8, wrongPIN: false, minimumLength: 4)),
                                  .pin(SecurityKeyPINPrompt(retries: 7, wrongPIN: true, minimumLength: 4)),
                                  .touch(several: false)], "\(pinSteps)")
        precondition(locked.log.filter { $0.hasPrefix("getPinUvAuthToken") } == ["getPinUvAuthToken:2:1:example.com", "getPinUvAuthToken:2:1:example.com"])
        precondition(locked.log.last == "makeCredential:example.com:rk=true:pin=true")
        precondition(locked.retries == 8)

        // PIN protocol one on a CTAP 2.0 key: getPinToken, and makeCredential always needs the PIN.
        let older = FakeKey()
        older.versions = ["U2F_V2", "FIDO_2_0"]
        older.pinProtocols = [1]
        older.pin = "246810"
        let (oldResult, _) = await run(.create(createRequest(uv: .discouraged)), [older], answers: [pin("246810")])
        _ = created(oldResult)
        precondition(older.log.contains("getPinToken:1") && older.log.contains("getKeyAgreement:1"), "\(older.log)")
        precondition(older.log.last == "makeCredential:example.com:rk=false:pin=true")

        // A short PIN is not sent, so it costs no retry.
        let counting = FakeKey()
        counting.pin = "1234"
        _ = created(await run(.create(createRequest(uv: .required)), [counting], answers: [pin("12"), pin("1234")]).0)
        precondition(counting.log.filter { $0.hasPrefix("getPinUvAuthToken") }.count == 1)

        // A key claiming a minimum PIN length past CTAP's 63-byte limit is held to 63.
        precondition(try! CTAP2.Info(.map([.int(1): .array([.text("FIDO_2_0")]), .int(3): .bytes(Data(count: 16)),
                                            .int(0x0d): .int(500)])).minPINLength == 63)
        let strict = FakeKey()
        strict.pin = String(repeating: "7", count: 63)
        strict.minPINLength = 200
        let (strictResult, strictSteps) = await run(.create(createRequest(uv: .required)), [strict], answers: [pin(strict.pin!)])
        _ = created(strictResult)
        precondition(strictSteps.first == .pin(SecurityKeyPINPrompt(retries: 8, wrongPIN: false, minimumLength: 63)), "\(strictSteps)")

        // A blocked PIN, a PIN-only site on a key without one, and leaving the PIN prompt.
        let blocked = FakeKey()
        blocked.pin = "1234"
        blocked.retries = 0
        let (blockedResult, blockedSteps) = await run(.create(createRequest(uv: .required)), [blocked], answers: [.dismissed])
        precondition(failed(blockedResult) == .notAllowed && blockedSteps.last == .failed(.pinBlocked))
        let (noPIN, noPINSteps) = await run(.get(getRequest(allow: [], uv: .required)), [FakeKey()], answers: [.dismissed])
        precondition(failed(noPIN) == .notAllowed && noPINSteps == [.failed(.pinRequired)])
        let leaving = FakeKey()
        leaving.pin = "1234"
        let (left, leftSteps) = await run(.create(createRequest(uv: .required)), [leaving], answers: [nil])
        precondition(failed(left) == .notAllowed && leftSteps.count == 1 && leaving.retries == 8)
        let guessing = FakeKey()
        guessing.pin = "1234"
        let (guessed, guessedSteps) = await run(.create(createRequest(uv: .required)), [guessing],
                                                answers: [pin("1111"), pin("2222"), pin("3333"), .dismissed])
        precondition(failed(guessed) == .notAllowed && guessedSteps.last == .failed(.pinAuthBlocked), "\(guessedSteps)")

        // excludeCredentials: the key waits for a touch, then says the credential is there.
        let (excluded, excludedSteps) = await run(.create(createRequest(exclude: [credential.credentialID])), [key], answers: [.dismissed])
        precondition(failed(excluded) == .invalidState && excludedSteps == [.touch(several: false), .failed(.alreadyRegistered)])
        let (algorithm, _) = await run(.create(createRequest(algorithms: [-8])), [FakeKey()], answers: [.dismissed])
        precondition(failed(algorithm) == .notSupported)

        // Several discoverable accounts: PIN, touch, then the picker; the second one signs.
        let shared = FakeKey()
        shared.pin = "1234"
        for name in ["alice", "bob"] {
            _ = created(await run(.create(createRequest(rk: .required, user: name)), [shared], answers: [pin("1234")]).0)
        }
        let discoverable = getRequest(allow: [])
        let (picked, pickedSteps) = await run(.get(discoverable), [shared], answers: [pin("1234"), .account(1)])
        let bob = asserted(picked)
        precondition(pickedSteps.last == .accounts([SecurityKeyAccount(id: 0, name: "alice", displayName: ""),
                                                    SecurityKeyAccount(id: 1, name: "bob", displayName: "")]), "\(pickedSteps)")
        precondition(bob.userHandle == Data("bob".utf8) && bob.credentialID == shared.credentials[1].id)
        precondition(shared.log.suffix(2) == ["getAssertion:example.com:allow=0:pin=true", "getNextAssertion"])
        let bobKey = shared.credentials[1].key.publicKey.derRepresentation
        precondition(verify(bob, publicKey: bobKey, clientDataJSON: discoverable.clientDataJSON))
        let (unpicked, _) = await run(.get(discoverable), [shared], answers: [pin("1234"), nil])
        precondition(failed(unpicked) == .notAllowed)

        // A credential this key does not hold.
        let (unknown, unknownSteps) = await run(.get(getRequest(allow: [Data(repeating: 1, count: 32)])), [key], answers: [.dismissed])
        precondition(failed(unknown) == .notAllowed && unknownSteps == [.touch(several: false), .failed(.notRegistered)])

        // A list longer than the key takes is probed in batches without a touch.
        let batching = FakeKey()
        batching.maxCredentialCountInList = 2
        let held = created(await run(.create(createRequest()), [batching]).0)
        let others = (1...4).map { Data(repeating: UInt8($0), count: 32) }
        let (batched, _) = await run(.get(getRequest(allow: [others[0], others[1], others[2], held.credentialID, others[3]])), [batching])
        precondition(asserted(batched).credentialID == held.credentialID)
        precondition(batching.log.suffix(3) == ["probe:2", "probe:2", "getAssertion:example.com:allow=1:pin=false"], "\(batching.log)")
        let (missing, _) = await run(.get(getRequest(allow: others)), [batching], answers: [.dismissed])
        precondition(failed(missing) == .notAllowed)

        // A key that demands a PIN mid-request gets one, and the request is sent again.
        let demanding = FakeKey()
        demanding.pin = "1234"
        demanding.requirePINForAssertion = true
        let kept = created(await run(.create(createRequest()), [demanding], answers: [pin("1234")]).0)
        let (demanded, _) = await run(.get(getRequest(allow: [kept.credentialID], uv: .discouraged)), [demanding], answers: [pin("1234")])
        precondition((try! AuthenticatorData(asserted(demanded).authenticatorData)).userVerified)
        precondition(demanding.log.filter { $0.hasPrefix("getAssertion") }
            == ["getAssertion:example.com:allow=1:pin=false", "getAssertion:example.com:allow=1:pin=true"], "\(demanding.log)")

        // Cancel while the key waits: CANCEL reaches the key and nothing else is shown.
        let waiting = FakeKey()
        waiting.autoTouch = false
        let (cancelled, cancelledSteps) = await run(.create(createRequest()), [waiting]) { step, ceremony in
            if step == .touch(several: false) { Task { @MainActor in await Task.yield(); ceremony.cancel() } }
        }
        await settle()
        precondition(failed(cancelled) == .notAllowed && cancelledSteps == [.touch(several: false)] && waiting.log.last == "cancel")

        // The page's timeout.
        let slow = FakeKey()
        slow.autoTouch = false
        let started = ContinuousClock.now
        let (timedOut, timedOutSteps) = await run(.create(createRequest(timeout: .milliseconds(300))), [slow])
        await settle()
        precondition(failed(timedOut) == .notAllowed && timedOutSteps == [.touch(several: false)] && slow.log.last == "cancel")
        precondition(ContinuousClock.now - started < .seconds(3))

        // Unplugged while waiting for a touch.
        let pulled = FakeKey()
        pulled.autoTouch = false
        pulled.onWaitingForTouch = { [weak pulled] in Task { @MainActor in pulled?.unplug() } }
        let (unplugged, unpluggedSteps) = await run(.create(createRequest()), [pulled], answers: [.dismissed])
        precondition(failed(unplugged) == .notAllowed && unpluggedSteps == [.touch(several: false), .failed(.removed)], "\(unpluggedSteps)")

        // Unplugged at the PIN prompt.
        let pulledAtPIN = FakeKey()
        pulledAtPIN.pin = "1234"
        let (pinUnplugged, pinUnpluggedSteps) = await run(.create(createRequest(uv: .required)), [pulledAtPIN]) { step, ceremony in
            if case .pin = step { Task { @MainActor in pulledAtPIN.unplug() } }
            if case .failed = step { Task { @MainActor in ceremony.cancel() } }
        }
        precondition(failed(pinUnplugged) == .notAllowed)
        precondition(pinUnpluggedSteps.count == 2 && pinUnpluggedSteps.last == .failed(.removed), "\(pinUnpluggedSteps)")

        // No key yet: the sheet asks for one, then the key plugged in is used.
        let late = FakeKey()
        let empty = FakeSource([])
        let (plugged, pluggedSteps) = await run(.create(createRequest()), [], source: empty) { step, _ in
            if step == .insert { Task { @MainActor in empty.plug(late) } }
        }
        _ = created(plugged)
        precondition(pluggedSteps == [.insert, .touch(several: false)] && late.credentials.count == 1)

        // Two keys: both wait for a touch; the one touched is used and the other is cancelled.
        let first = FakeKey(), second = FakeKey()
        first.autoTouch = false
        second.autoTouch = false
        first.versions = ["FIDO_2_0"]
        let firstLogWhenSecondUsed = Journal()
        second.onWaitingForTouch = { [weak second] in
            guard second?.log.last == "selection" else {
                firstLogWhenSecondUsed.lines = first.log
                return
            }
            Task { @MainActor in
                second?.autoTouch = true
                second?.touch()
            }
        }
        let (chosen, chosenSteps) = await run(.create(createRequest()), [first, second])
        _ = created(chosen)
        precondition(chosenSteps == [.touch(several: true), .touch(several: false)], "\(chosenSteps)")
        precondition(firstLogWhenSecondUsed.lines == ["init", "getInfo", "makeCredential:selection", "cancel"], "\(firstLogWhenSecondUsed.lines)")
        precondition(first.log == ["init", "getInfo", "makeCredential:selection", "cancel"], "\(first.log)")
        precondition(second.log == ["init", "getInfo", "selection", "makeCredential:example.com:rk=false:pin=false"], "\(second.log)")
        precondition(first.credentials.isEmpty && second.credentials.count == 1)

        // Two ceremonies at once: the second is refused and the first goes on.
        let busy = FakeKey()
        busy.autoTouch = false
        let refused = Box()
        let (firstResult, _) = await run(.create(createRequest()), [busy]) { step, _ in
            guard step == .touch(several: false) else { return }
            Task { @MainActor in
                let user = FakeUser()
                refused.result = await SecurityKeyCeremony(.create(createRequest()), source: FakeSource([FakeKey()]), user: user).run()
                precondition(user.steps.isEmpty)
                busy.autoTouch = true
                busy.touch()
            }
        }
        _ = created(firstResult)
        precondition(refused.result.flatMap(failed) == .notAllowed)

        // A U2F-only key, and a key whose reply names another site.
        let u2f = FakeKey()
        u2f.u2fOnly = true
        let (u2fResult, u2fSteps) = await run(.create(createRequest()), [u2f], answers: [.dismissed])
        precondition(failed(u2fResult) == .notAllowed && u2fSteps == [.failed(.unsupported)])
        let liar = FakeKey()
        liar.answersForRP = "evil.example"
        let (lied, liedSteps) = await run(.create(createRequest()), [liar], answers: [.dismissed])
        precondition(failed(lied) == .notAllowed && liedSteps.last == .failed(.failed))

        print("SecurityKeyCeremonyCheck passed")
    }
}
