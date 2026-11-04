// Licensed under GPL-3.0. See LICENSE.
//
//  SecurityKeyHIDFramingCheck.swift
//  Nook
//
//  CTAPHID framing (CTAP 2.1 §11.2): initialization and continuation packets, the 7609-byte
//  limit, reassembly across reports, other channels ignored, keepalive and error packets, bad
//  sequence numbers, and the INIT reply. Run from the repository root:
//
//    swiftc -parse-as-library Packages/NookWeb/Sources/NookWeb/SecurityKey/CTAPHID.swift \
//           Packages/NookWeb/Checks/SecurityKeyHIDFramingCheck.swift -o /tmp/sk-hid && /tmp/sk-hid
//

import Foundation

@main
struct SecurityKeyHIDFramingCheck {
    static func hex(_ text: String) -> Data {
        let chars = Array(text.lowercased().filter { !$0.isWhitespace })
        return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0 + 1]), radix: 16)! })
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    static func zeros(_ count: Int) -> String { String(repeating: "00", count: count) }

    static func failure(_ body: () throws -> CTAPHID.Assembler.Event?) -> CTAPHID.Assembler.Failure? {
        do {
            _ = try body()
            return nil
        } catch {
            return error as? CTAPHID.Assembler.Failure
        }
    }

    static func main() {
        precondition(CTAPHID.maxPayload == 7609)

        // INIT on the broadcast channel with an 8-byte nonce: one zero-padded report.
        let initPackets = CTAPHID.packets(channel: CTAPHID.broadcastChannel, command: .initialize, payload: hex("0102030405060708"))!
        precondition(initPackets.map(hex) == ["ffffffff860008" + "0102030405060708" + zeros(49)])

        // An empty CANCEL, and a 57-byte payload that just fits the first report.
        precondition(CTAPHID.packets(channel: 0x0a0b0c0d, command: .cancel, payload: Data())!.map(hex) == ["0a0b0c0d910000" + zeros(57)])
        let fits = Data(repeating: 0xaa, count: 57)
        precondition(CTAPHID.packets(channel: 1, command: .cbor, payload: fits)!.map(hex) == ["00000001900039" + hex(fits)])

        // 58 bytes: the 58th goes to continuation 0.
        let spill = CTAPHID.packets(channel: 1, command: .cbor, payload: Data(repeating: 0xbb, count: 57) + Data([0xcc]))!
        precondition(spill.count == 2 && spill.allSatisfy { $0.count == 64 })
        precondition(hex(spill[0]).hasPrefix("0000000190003abbbb") && hex(spill[1]) == "0000000100cc" + zeros(58))

        // The largest message takes 129 reports, sequences 0...127; one byte more is refused.
        let largest = Data((0..<CTAPHID.maxPayload).map { UInt8($0 & 0xff) })
        let reports = CTAPHID.packets(channel: 7, command: .cbor, payload: largest)!
        precondition(reports.count == 129 && reports.last![4] == 127)
        precondition(CTAPHID.packets(channel: 7, command: .cbor, payload: largest + Data([0])) == nil)

        // Reassembly gives back exactly what was framed.
        var assembler = CTAPHID.Assembler(channel: 7)
        var events: [CTAPHID.Assembler.Event] = []
        for report in reports { if let event = try! assembler.add(report) { events.append(event) } }
        precondition(events == [.message(command: 0x10, payload: largest)])

        // Other channels are ignored, even mid-message; keepalives and errors come through.
        var mixed = CTAPHID.Assembler(channel: 1)
        precondition(try! mixed.add(spill[0]) == nil)
        precondition(try! mixed.add(hex("00000002bb0001" + "02" + zeros(56))) == nil)
        precondition(try! mixed.add(hex("00000002" + "00" + zeros(59))) == nil)
        precondition(try! mixed.add(spill[1]) == .message(command: 0x10, payload: Data(repeating: 0xbb, count: 57) + Data([0xcc])))
        precondition(try! mixed.add(hex("00000001bb0001" + "02" + zeros(56))) == .keepalive(2))
        precondition(try! mixed.add(hex("00000001bb0001" + "01" + zeros(56))) == .keepalive(1))
        precondition(try! mixed.add(hex("00000001bf0001" + "06" + zeros(56))) == .error(6))

        // A continuation with no message under way is stale and ignored; a skipped sequence is an error.
        var stale = CTAPHID.Assembler(channel: 1)
        precondition(try! stale.add(spill[1]) == nil)
        var skipped = CTAPHID.Assembler(channel: 7)
        _ = try! skipped.add(reports[0])
        _ = try! skipped.add(reports[1])
        precondition(failure { try skipped.add(reports[3]) } == .badSequence)
        var short = CTAPHID.Assembler(channel: 1)
        precondition(failure { try short.add(Data([0, 0, 0, 1, 0x90])) } == .malformed)
        var oversize = CTAPHID.Assembler(channel: 1)
        precondition(failure { try oversize.add(hex("0000000190ffff" + zeros(57))) } == .malformed)
        // A keepalive or error that ends before its status byte is malformed, not a crash.
        var shortKeepalive = CTAPHID.Assembler(channel: 1)
        precondition(failure { try shortKeepalive.add(hex("00000001bb0001")) } == .malformed)
        var shortError = CTAPHID.Assembler(channel: 1)
        precondition(failure { try shortError.add(hex("00000001bf0001")) } == .malformed)

        // INIT reply: our nonce, the new channel, protocol 2, version 5.4.3, CBOR and WINK.
        let nonce = hex("0102030405060708")
        let reply = hex("0102030405060708" + "11223344" + "02" + "050403" + "05")
        let parsed = CTAPHID.InitResponse(reply, nonce: nonce)!
        precondition(parsed.channel == 0x1122_3344 && parsed.protocolVersion == 2 && parsed.supportsCBOR)
        precondition(parsed.deviceVersion == (5, 4, 3))
        precondition(CTAPHID.InitResponse(reply, nonce: hex("0102030405060709")) == nil)
        precondition(CTAPHID.InitResponse(reply.prefix(16), nonce: nonce) == nil)
        precondition(CTAPHID.InitResponse(hex("0102030405060708" + "ffffffff" + "02050403" + "05"), nonce: nonce) == nil)
        precondition(CTAPHID.InitResponse(hex("0102030405060708" + "00000000" + "02050403" + "05"), nonce: nonce) == nil)
        precondition(!CTAPHID.InitResponse(hex("0102030405060708" + "11223344" + "02050403" + "01"), nonce: nonce)!.supportsCBOR)

        print("SecurityKeyHIDFramingCheck passed")
    }
}
