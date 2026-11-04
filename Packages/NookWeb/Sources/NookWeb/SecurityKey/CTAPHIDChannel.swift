// Licensed under GPL-3.0. See LICENSE.
//
//  CTAPHIDChannel.swift
//  Nook
//
//  One CTAPHID channel on one FIDO HID device: INIT with a random nonce to get a channel, then
//  one CBOR transaction at a time. Keepalives reach the caller; CANCEL ends the transaction at
//  once; unplugging, a CTAPHID error, or five seconds of silence fail it.
//

import Foundation

/// A FIDO HID device: 64-byte output reports out, input reports in.
@MainActor
public protocol SecurityKeyHID: AnyObject {
    /// Each input report, and nil once when the device goes away.
    var onInput: ((Data?) -> Void)? { get set }
    /// Sends one 64-byte output report; false when the device did not take it.
    func write(_ report: Data) -> Bool
}

/// Where FIDO HID devices come from: IOHIDManager in the app, a fake in checks.
@MainActor
public protocol SecurityKeyHIDSource: AnyObject {
    /// Starts watching; returns the devices plugged in now and calls `arrived` for each one
    /// plugged in later, until `stop()`.
    func start(arrived: @escaping (SecurityKeyHID) -> Void) -> [SecurityKeyHID]
    func stop()
}

@MainActor
final class CTAPHIDChannel {
    enum Failure: Error, Equatable {
        case removed
        case cancelled
        case silent
        case writeFailed
        case malformed
        /// A U2F-only device.
        case noCBOR
        case hidError(UInt8)
    }

    static let silenceLimit: Duration = .seconds(5)

    private let device: SecurityKeyHID
    private var channel = CTAPHID.broadcastChannel
    private var assembler = CTAPHID.Assembler(channel: CTAPHID.broadcastChannel)
    private var expectedCommand: UInt8 = 0
    private var initNonce: Data?
    private var pending: CheckedContinuation<Data, Error>?
    private var keepalive: ((UInt8) -> Void)?
    private var watchdog: Task<Void, Never>?
    private(set) var isRemoved = false
    var onRemoved: (() -> Void)?

    init(device: SecurityKeyHID) {
        self.device = device
        device.onInput = { [weak self] report in self?.received(report) }
    }

    /// CTAPHID_INIT on the broadcast channel; the device must speak CBOR.
    func open() async throws {
        var random = SystemRandomNumberGenerator()
        let nonce = Data((0..<8).map { _ in UInt8.random(in: .min ... .max, using: &random) })
        initNonce = nonce
        let payload = try await transact(.initialize, payload: nonce, keepalive: nil)
        guard let reply = CTAPHID.InitResponse(payload, nonce: nonce) else { throw Failure.malformed }
        guard reply.supportsCBOR else { throw Failure.noCBOR }
        channel = reply.channel
        assembler = CTAPHID.Assembler(channel: reply.channel)
    }

    /// One CTAP2 command; the status byte and the decoded reply, if any.
    func cbor(_ command: CTAP2.Command, _ parameters: CBOR?, keepalive: ((UInt8) -> Void)?) async throws -> (status: UInt8, reply: CBOR?) {
        let payload = Data([command.rawValue]) + (parameters?.encoded ?? Data())
        let response = try await transact(.cbor, payload: payload, keepalive: keepalive)
        guard let status = response.first else { throw Failure.malformed }
        guard response.count > 1 else { return (status, nil) }
        guard let reply = try? CBOR.decode(response.dropFirst()) else { throw Failure.malformed }
        return (status, reply)
    }

    /// Sends CTAPHID_CANCEL and ends the transaction under way with `.cancelled`.
    func cancel() {
        guard pending != nil else { return }
        if !isRemoved, let packets = CTAPHID.packets(channel: channel, command: .cancel, payload: Data()) {
            packets.forEach { _ = device.write($0) }
        }
        finish(.failure(Failure.cancelled))
    }

    /// Stops listening; a transaction under way ends with `.cancelled`.
    func close() {
        cancel()
        device.onInput = nil
        onRemoved = nil
    }

    private func transact(_ command: CTAPHID.Command, payload: Data, keepalive: ((UInt8) -> Void)?) async throws -> Data {
        guard !isRemoved else { throw Failure.removed }
        guard pending == nil, let packets = CTAPHID.packets(channel: channel, command: command, payload: payload)
        else { throw Failure.malformed }
        expectedCommand = command.rawValue
        if command == .initialize { assembler = CTAPHID.Assembler(channel: CTAPHID.broadcastChannel) }
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            self.keepalive = keepalive
            for packet in packets where !device.write(packet) {
                return finish(.failure(Failure.writeFailed))
            }
            if pending != nil { armWatchdog() }
        }
    }

    private func received(_ report: Data?) {
        guard let report else {
            isRemoved = true
            finish(.failure(Failure.removed))
            onRemoved?()
            return
        }
        guard pending != nil else { return }
        let event: CTAPHID.Assembler.Event?
        do {
            event = try assembler.add(report)
        } catch {
            return finish(.failure(Failure.malformed))
        }
        guard let event else { return armWatchdog() }
        switch event {
        case .keepalive(let status):
            armWatchdog()
            keepalive?(status)
        case .error(let code):
            finish(.failure(Failure.hidError(code)))
        case .message(let command, let payload):
            guard command == expectedCommand else { return finish(.failure(Failure.malformed)) }
            // A broadcast INIT reply may answer another program's nonce.
            if command == CTAPHID.Command.initialize.rawValue, let nonce = initNonce,
               CTAPHID.InitResponse(payload, nonce: nonce) == nil {
                return armWatchdog()
            }
            finish(.success(payload))
        }
    }

    private func armWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.silenceLimit)
            guard !Task.isCancelled else { return }
            self?.finish(.failure(Failure.silent))
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        watchdog?.cancel()
        watchdog = nil
        keepalive = nil
        let continuation = pending
        pending = nil
        continuation?.resume(with: result)
    }
}
