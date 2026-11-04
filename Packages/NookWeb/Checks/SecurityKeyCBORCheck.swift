// Licensed under GPL-3.0. See LICENSE.
//
//  SecurityKeyCBORCheck.swift
//  Nook
//
//  CBOR for CTAP2: the RFC 8949 Appendix A vectors in the supported subset, CTAP2 canonical
//  map key order, refusal of malformed or unsupported input, and real authenticator replies
//  from python-fido2's tests (tests/test_ctap2.py, BSD-2-Clause, Yubico AB). Run from the
//  repository root:
//
//    swiftc -parse-as-library Packages/NookWeb/Sources/NookWeb/SecurityKey/CBOR.swift \
//           Packages/NookWeb/Checks/SecurityKeyCBORCheck.swift -o /tmp/sk-cbor && /tmp/sk-cbor
//

import Foundation

@main
struct SecurityKeyCBORCheck {
    static func hex(_ text: String) -> Data {
        let chars = Array(text.lowercased().filter { !$0.isWhitespace })
        return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0 + 1]), radix: 16)! })
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    static func roundTrip(_ value: CBOR, _ expected: String, line: UInt = #line) {
        precondition(hex(value.encoded) == expected, "encode \(value): \(hex(value.encoded)) != \(expected)", line: line)
        precondition(try! CBOR.decode(hex(expected)) == value, "decode \(expected)", line: line)
    }

    static func refuses(_ input: String, _ failure: CBOR.Failure, line: UInt = #line) {
        do {
            _ = try CBOR.decode(hex(input))
            preconditionFailure("accepted \(input)", line: line)
        } catch let error as CBOR.Failure {
            precondition(error == failure, "\(input): \(error) != \(failure)", line: line)
        } catch {
            preconditionFailure("\(input): \(error)", line: line)
        }
    }

    static func main() {
        // RFC 8949 Appendix A.
        roundTrip(.unsigned(0), "00")
        roundTrip(.unsigned(1), "01")
        roundTrip(.unsigned(10), "0a")
        roundTrip(.unsigned(23), "17")
        roundTrip(.unsigned(24), "1818")
        roundTrip(.unsigned(25), "1819")
        roundTrip(.unsigned(100), "1864")
        roundTrip(.unsigned(1000), "1903e8")
        roundTrip(.unsigned(1_000_000), "1a000f4240")
        roundTrip(.unsigned(1_000_000_000_000), "1b000000e8d4a51000")
        roundTrip(.unsigned(18_446_744_073_709_551_615), "1bffffffffffffffff")
        roundTrip(.negative(18_446_744_073_709_551_615), "3bffffffffffffffff")
        roundTrip(.int(-1), "20")
        roundTrip(.int(-10), "29")
        roundTrip(.int(-100), "3863")
        roundTrip(.int(-1000), "3903e7")
        roundTrip(.bool(false), "f4")
        roundTrip(.bool(true), "f5")
        roundTrip(.null, "f6")
        roundTrip(.bytes(Data()), "40")
        roundTrip(.bytes(Data([1, 2, 3, 4])), "4401020304")
        roundTrip(.text(""), "60")
        roundTrip(.text("a"), "6161")
        roundTrip(.text("IETF"), "6449455446")
        roundTrip(.text("\"\\"), "62225c")
        roundTrip(.text("\u{00fc}"), "62c3bc")
        roundTrip(.text("\u{6c34}"), "63e6b0b4")
        roundTrip(.text("\u{10151}"), "64f0908591")
        roundTrip(.array([]), "80")
        roundTrip(.array([.int(1), .int(2), .int(3)]), "83010203")
        roundTrip(.array([.int(1), .array([.int(2), .int(3)]), .array([.int(4), .int(5)])]), "8301820203820405")
        roundTrip(.array((1...25).map { .int($0) }), "98190102030405060708090a0b0c0d0e0f101112131415161718181819")
        roundTrip(.map([:]), "a0")
        roundTrip(.map([.int(1): .int(2), .int(3): .int(4)]), "a201020304")
        roundTrip(.map([.text("a"): .int(1), .text("b"): .array([.int(2), .int(3)])]), "a26161016162820203")
        roundTrip(.array([.text("a"), .map([.text("b"): .text("c")])]), "826161a161626163")
        roundTrip(.map([.text("a"): .text("A"), .text("b"): .text("B"), .text("c"): .text("C"),
                        .text("d"): .text("D"), .text("e"): .text("E")]),
                  "a56161614161626142616361436164614461656145")

        // CTAP2 canonical key order: major type, then length, then bytes. Integers sort
        // 0..23, 24.., then negatives -1, -2, ...; text by length first.
        roundTrip(.map([.text("3"): .int(0), .bytes(Data("2".utf8)): .int(0), .int(1): .int(0)]), "a30100413200613300")
        roundTrip(.map([.text("3"): .int(0), .bytes(Data()): .int(0), .int(256): .int(0)]), "a3190100004000613300")
        roundTrip(.map([.int(4_294_967_296): .int(0), .int(255): .int(0), .int(256): .int(0), .int(0): .int(0)]),
                  "a4000018ff00190100001b000000010000000000")
        roundTrip(.map([.text("22"): .int(0), .text("3"): .int(0)]), "a26133006232320 0".replacingOccurrences(of: " ", with: ""))
        roundTrip(.map([.text("001"): .int(0), .text("003"): .int(0), .text("002"): .int(0)]), "a3633030310063303032006330303300")
        roundTrip(.map([.bool(true): .int(0), .bool(false): .int(0)]), "a2f400f500")
        // Length before bytes: [-1] (8120) ahead of [100] (811864), unlike plain bytewise order.
        roundTrip(.map([.array([.int(100)]): .int(0), .array([.int(-1)]): .int(0)]), "a2812000811864 00".replacingOccurrences(of: " ", with: ""))
        // A COSE key: 1, 3, then -1, -2, -3.
        roundTrip(.map([.int(-3): .bytes(Data([3])), .int(1): .int(2), .int(-1): .int(1), .int(3): .int(-7), .int(-2): .bytes(Data([2]))]),
                  "a5010203262001214102224103")
        // A credential descriptor: "id" before "type"; options "rk" "up" "uv" by bytes.
        roundTrip(.map([.text("type"): .text("public-key"), .text("id"): .bytes(Data([0xaa]))]),
                  "a2626964 41aa 6474797065 6a7075626c69632d6b6579".replacingOccurrences(of: " ", with: ""))
        roundTrip(.map([.text("uv"): .bool(true), .text("rk"): .bool(true), .text("up"): .bool(false)]), "a362726bf5627570f4627576f5")

        // Decoding accepts any key order but refuses what CTAP2 never sends.
        precondition(try! CBOR.decode(hex("a203040102")) == .map([.int(1): .int(2), .int(3): .int(4)]))
        refuses("", .truncated)
        refuses("18", .truncated)
        refuses("1a0000", .truncated)
        refuses("44010203", .truncated)
        refuses("63e6b0", .truncated)
        refuses("83010203" + "04", .trailingBytes)
        refuses("5a7fffffff00", .truncated)
        refuses("9bffffffffffffffff00", .truncated)
        refuses("bbffffffffffffffff00", .truncated)
        refuses("a2010201 03".replacingOccurrences(of: " ", with: ""), .duplicateKey)
        refuses("5f42010243030405ff", .unsupported)          // indefinite byte string
        refuses("9fff", .unsupported)                        // indefinite array
        refuses("c11a514b67b0", .unsupported)                // tag 1
        refuses("f93c00", .unsupported)                      // half float 1.0
        refuses("fb3ff199999999999a", .unsupported)          // double 1.1
        refuses("f7", .unsupported)                          // undefined
        refuses("1c", .unsupported)                          // reserved additional info
        refuses("62c328", .invalidText)                      // invalid UTF-8
        refuses(String(repeating: "81", count: CBOR.maxDepth + 1) + "00", .tooDeep)
        precondition(try! CBOR.decode(hex(String(repeating: "81", count: CBOR.maxDepth) + "00")).array != nil)

        // Decoding from inside a buffer stops after one item.
        var offset = 1
        precondition(try! CBOR.decode(hex("ff a20102 0304 ee".replacingOccurrences(of: " ", with: "")), from: &offset)
            == .map([.int(1): .int(2), .int(3): .int(4)]) && offset == 6)

        // authenticatorGetInfo from a FIDO_2_0 key.
        let info = try! CBOR.decode(hex(
            "a60182665532465f5632684649444f5f325f3002826375766d6b686d61632d7365637265740350f8a011f38c0a4d15800617111f9edc7d04a462726bf5627570f564706c6174f469636c69656e7450696ef4051904b0068101"))
        precondition(info[1] == .array([.text("U2F_V2"), .text("FIDO_2_0")]))
        precondition(info[2] == .array([.text("uvm"), .text("hmac-secret")]))
        precondition(info[3]?.bytes == hex("F8A011F38C0A4D15800617111F9EDC7D"))
        precondition(info[4] == .map([.text("rk"): .bool(true), .text("up"): .bool(true), .text("plat"): .bool(false),
                                      .text("clientPin"): .bool(false)]))
        precondition(info[5]?.int == 1200 && info[6] == .array([.int(1)]))
        precondition(hex(info.encoded) == "a60182665532465f5632684649444f5f325f3002826375766d6b686d61632d7365637265740350f8a011f38c0a4d15800617111f9edc7d04a462726bf5627570f564706c6174f469636c69656e7450696ef4051904b0068101")

        // authenticatorMakeCredential and authenticatorGetAssertion replies.
        let credentialID = hex("FE3AAC036D14C1E1C65518B698DD1DA8F596BC33E11072813466C6BF3845691509B80FB76D59309B8D39E0A93452688F6CA3A39A76F3FC52744FB73948B15783")
        let makeCredential = hex(
            "a301667061636b65640258c40021f5fc0b85cd22e60623bcd7d1ca48948909249b4776eb515154e57b66ae12410000001cf8a011f38c0a4d15800617111f9edc7d0040fe3aac036d14c1e1c65518b698dd1da8f596bc33e11072813466c6bf3845691509b80fb76d59309b8d39e0a93452688f6ca3a39a76f3fc52744fb73948b15783a5010203262001215820643566c206dd00227005fa5de69320616ca268043a38f08bde2e9dc45a5cafaf225820171353b2932434703726aae579fa6542432861fe591e481ea22d63997e1a529003a363616c67266373696758483046022100cc1ef43edf07de8f208c21619c78a565ddcf4150766ad58781193be8e0a742ed022100f1ed7c7243e45b7d8e5bda6b1abf10af7391789d1ef21b70bd69fed48dba4cb163783563815901973082019330820138a003020102020900859b726cb24b4c29300a06082a8648ce3d0403023047310b300906035504061302555331143012060355040a0c0b59756269636f205465737431223020060355040b0c1941757468656e74696361746f72204174746573746174696f6e301e170d3136313230343131353530305a170d3236313230323131353530305a3047310b300906035504061302555331143012060355040a0c0b59756269636f205465737431223020060355040b0c1941757468656e74696361746f72204174746573746174696f6e3059301306072a8648ce3d020106082a8648ce3d03010703420004ad11eb0e8852e53ad5dfed86b41e6134a18ec4e1af8f221a3c7d6e636c80ea13c3d504ff2e76211bb44525b196c44cb4849979cf6f896ecd2bb860de1bf4376ba30d300b30090603551d1304023000300a06082a8648ce3d0403020349003046022100e9a39f1b03197525f7373e10ce77e78021731b94d0c03f3fda1fd22db3d030e7022100c4faec3445a820cf43129cdb00aabefd9ae2d874f9c5d343cb2f113da23723f3")
        let attestation = try! CBOR.decode(makeCredential)
        precondition(attestation[1] == .text("packed"))
        let authData = attestation[2]!.bytes!
        precondition(authData.count == 196 && authData.subdata(in: 55..<119) == credentialID)
        precondition(attestation[3]?["alg"]?.int == -7 && attestation[3]?["sig"]?.bytes?.count == 72)
        precondition(attestation[3]?["x5c"]?.array?.first?.bytes?.count == 407)
        precondition(attestation.encoded == makeCredential)
        var coseOffset = 119
        let cose = try! CBOR.decode(authData, from: &coseOffset)
        precondition(coseOffset == authData.count && cose[1]?.int == 2 && cose[3]?.int == -7 && cose[-1]?.int == 1)
        precondition(cose[-2]?.bytes == hex("643566c206dd00227005fa5de69320616ca268043a38f08bde2e9dc45a5cafaf"))

        let getAssertion = hex(
            "a301a26269645840fe3aac036d14c1e1c65518b698dd1da8f596bc33e11072813466c6bf3845691509b80fb76d59309b8d39e0a93452688f6ca3a39a76f3fc52744fb73948b1578364747970656a7075626c69632d6b65790258250021f5fc0b85cd22e60623bcd7d1ca48948909249b4776eb515154e57b66ae12010000001d035846304402206765cbf6e871d3af7f01ae96f06b13c90f26f54b905c5166a2c791274fc2397102200b143893586cc799fba4da83b119eaea1bd80ac3ce88fcedb3efbd596a1f4f63")
        let assertion = try! CBOR.decode(getAssertion)
        precondition(assertion[1] == .map([.text("id"): .bytes(credentialID), .text("type"): .text("public-key")]))
        precondition(assertion[2]?.bytes == hex("0021F5FC0B85CD22E60623BCD7D1CA48948909249B4776EB515154E57B66AE12010000001D"))
        precondition(assertion[3]?.bytes?.count == 70 && assertion.encoded == getAssertion)

        print("SecurityKeyCBORCheck passed")
    }
}
