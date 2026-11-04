// Licensed under GPL-3.0. See LICENSE.
//
//  SecurityKeyPINCheck.swift
//  Nook
//
//  PIN/UV auth protocols one and two against published vectors: python-fido2's ClientPin tests
//  (tests/test_ctap2.py: ECDH with a fixed key, getPinToken, setPin, changePin) and
//  authenticator-rs's protocol-two KDF (src/crypto/mod.rs, test_pin_uv_auth2_kdf). Protocol-two
//  ECDH, AES and HMAC outputs over the same keys were reproduced with OpenSSL 3.2 and Python's
//  hmac. Run from the repository root:
//
//    swiftc -parse-as-library Packages/NookWeb/Sources/NookWeb/SecurityKey/CBOR.swift \
//           Packages/NookWeb/Sources/NookWeb/SecurityKey/PinUvAuthProtocol.swift \
//           Packages/NookWeb/Checks/SecurityKeyPINCheck.swift -o /tmp/sk-pin && /tmp/sk-pin
//

import CryptoKit
import Foundation

@main
struct SecurityKeyPINCheck {
    static func hex(_ text: String) -> Data {
        let chars = Array(text.lowercased().filter { !$0.isWhitespace })
        return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0 + 1]), radix: 16)! })
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    static let platformPrivate = hex("7452E599FEE739D8A653F6A507343D12D382249108A651402520B72F24FE7684")
    static let platformX = hex("44D78D7989B97E62EA993496C9EF6E8FD58B8B00715F9A89153DDD9C4657E47F")
    static let platformY = hex("EC802EE7D22BD4E100F12E48537EB4E7E96ED3A47A0A3BD5F5EEAB65001664F9")
    static let deviceKey = CBOR.map([.int(1): .int(2), .int(3): .int(-25), .int(-1): .int(1),
                                     .int(-2): .bytes(hex("0501D5BC78DA9252560A26CB08FCC60CBE0B6D3B8E1D1FCEE514FAC0AF675168")),
                                     .int(-3): .bytes(hex("D551B3ED46F665731F95B4532939C25D91DB7EB844BD96D4ABD4083785F8DF47"))])
    static let shared1 = hex("c42a039d548100dfba521e487debcbbb8b66bb7496f8b1862a7a395ed83e1a1c")

    static func throwsFailure(_ body: () throws -> Any) -> PinUvAuthProtocol.Failure? {
        do {
            _ = try body()
            return nil
        } catch {
            return error as? PinUvAuthProtocol.Failure
        }
    }

    static func padded(_ pin: String) -> Data {
        Data(pin.utf8) + Data(repeating: 0, count: 64 - pin.utf8.count)
    }

    static func main() throws {
        let privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: platformPrivate)
        let message = Data(0..<32)

        // Protocol choice: two when offered; one for keys that list one or nothing.
        precondition(PinUvAuthProtocol.preferred(from: [1, 2]) == .two && PinUvAuthProtocol.preferred(from: [2]) == .two)
        precondition(PinUvAuthProtocol.preferred(from: [1]) == .one && PinUvAuthProtocol.preferred(from: []) == .one)
        precondition(PinUvAuthProtocol.preferred(from: [3]) == nil)

        // Protocol one (python-fido2).
        let one = PinUvAuthProtocol.one
        let (agreement, secret1) = try one.encapsulate(peer: deviceKey, privateKey: privateKey)
        precondition(secret1 == shared1, hex(secret1))
        precondition(agreement == .map([.int(1): .int(2), .int(3): .int(-25), .int(-1): .int(1),
                                        .int(-2): .bytes(platformX), .int(-3): .bytes(platformY)]))
        let pinHash = PinUvAuthProtocol.pinHash(Data("1234".utf8))
        precondition(hex(pinHash) == "03ac674216f3e15c761ee1a5e255f067")
        precondition(hex(try! one.encrypt(key: shared1, plaintext: pinHash)) == "afe8327ce416da8ee3d057589c2ce1a9")
        precondition(hex(try! one.decrypt(key: shared1, ciphertext: hex("7A9F98E31B77BE90F9C64D12E9635040"))) == "aff12c6dcfbf9df52f7a09211e8865cd")
        let newPin = try one.encrypt(key: shared1, plaintext: padded("1234"))
        precondition(hex(newPin) == "0222fc42c6dd76a274a7057858b9b29d98e8a722ec2dc6668476168c5320473cec9907b4cd76ce7943c96ba5683943211d84471e64d9c51e54763488cd66526a")
        precondition(hex(one.authenticate(key: shared1, message: newPin)) == "7b40c084ccc5794194189ab57836475f")
        let changed = try one.encrypt(key: shared1, plaintext: padded("4321"))
        precondition(hex(changed) == "4280e14aac4fcbf02dd079985f0c0ffc9ea7d5f9c173fd1a4c843826f7590cb3c2d080c6923e2fe6d7a52c31ea1309d3fcca3dedae8a2ef14b6330cafc79339e")
        precondition(hex(one.authenticate(key: shared1, message: changed + hex("afe8327ce416da8ee3d057589c2ce1a9"))) == "fb97e92f3724d7c85e001d7f93e6490a")
        precondition(hex(one.authenticate(key: hex("aff12c6dcfbf9df52f7a09211e8865cd"), message: message)) == "b8b3ca7f8ce44f3b2d19e74a3681aaa1")
        precondition(throwsFailure { try one.decrypt(key: shared1, ciphertext: Data(count: 15)) } == .badCiphertext)
        precondition(throwsFailure { try one.decrypt(key: shared1, ciphertext: Data()) } == .badCiphertext)
        precondition(throwsFailure { try one.encrypt(key: shared1, plaintext: Data(count: 15)) } == .cryptoFailed)

        // Protocol two: authenticator-rs's KDF vector, then the python-fido2 keys through it.
        let two = PinUvAuthProtocol.two
        precondition(hex(two.kdf(Data(repeating: 0xff, count: 32))).uppercased()
            == "570B4ED82AA5DFB49DB79DBEAF4B315D8ABB1A9867B245F3367026987C0D47A17D9A93C39BAEC741D141C6238D8E1846DE323D8EED022CB397D19A73B98945E2")
        let (agreement2, secret2) = try two.encapsulate(peer: deviceKey, privateKey: privateKey)
        precondition(agreement2 == agreement)
        // Z is 001bc4b2…: its leading zero byte stays in.
        precondition(hex(secret2) == "65ef955dd8cfcacab489ad582d64b872299cec1970aeffb10c90b9d9f4b4f1a746cc03964825ccbaf159fde1958b2063871bd5b66ecf28972eaac583214a22d8")
        precondition(two.kdf(hex("001bc4b24d2372ce13715cbf731e660586bb713408f0d1f5ad79cb1088f9e53c")) == secret2)
        precondition(one.kdf(hex("001bc4b24d2372ce13715cbf731e660586bb713408f0d1f5ad79cb1088f9e53c")) == shared1)

        let iv = Data(0..<16)
        let pinHashEnc2 = try two.encrypt(key: secret2, plaintext: pinHash, iv: iv)
        precondition(hex(pinHashEnc2) == "000102030405060708090a0b0c0d0e0f" + "09870d15a35707bcc287efb5be976011")
        precondition(try! two.decrypt(key: secret2, ciphertext: pinHashEnc2) == pinHash)
        let random1 = try two.encrypt(key: secret2, plaintext: pinHash), random2 = try two.encrypt(key: secret2, plaintext: pinHash)
        precondition(random1.count == 32 && random1 != random2 && random1.prefix(16) != random2.prefix(16))
        precondition(try! two.decrypt(key: secret2, ciphertext: random1) == pinHash)
        precondition(throwsFailure { try two.decrypt(key: secret2, ciphertext: iv) } == .badCiphertext)
        precondition(throwsFailure { try two.decrypt(key: secret2, ciphertext: Data(count: 40)) } == .badCiphertext)
        precondition(throwsFailure { try two.encrypt(key: shared1, plaintext: pinHash) } == .cryptoFailed)

        // HMAC: the first half of a shared secret, or a whole 32-byte token; all 32 bytes.
        precondition(hex(two.authenticate(key: secret2, message: message)) == "863a441005ab45ded7e0b81eb4edc5b0ee783635c264e5adff5b22b0da036af4")
        precondition(hex(two.authenticate(key: Data(repeating: 0x11, count: 32), message: message)) == "74b9ee840de5d5a97a0a075fb825e319f4f1fd18e73809ef1dd0cd89fe5921b5")

        // A key-agreement key that is not a P-256 point, or not EC2 P-256, is refused.
        var offCurve = deviceKey.map!
        offCurve[.int(-3)] = .bytes(Data(repeating: 1, count: 32))
        precondition(throwsFailure { try two.encapsulate(peer: .map(offCurve)) } == .badKeyAgreement)
        var wrongCurve = deviceKey.map!
        wrongCurve[.int(-1)] = .int(2)
        precondition(throwsFailure { try two.encapsulate(peer: .map(wrongCurve)) } == .badKeyAgreement)
        var shortX = deviceKey.map!
        shortX[.int(-2)] = .bytes(Data(repeating: 1, count: 31))
        precondition(throwsFailure { try one.encapsulate(peer: .map(shortX)) } == .badKeyAgreement)

        print("SecurityKeyPINCheck passed")
    }
}
