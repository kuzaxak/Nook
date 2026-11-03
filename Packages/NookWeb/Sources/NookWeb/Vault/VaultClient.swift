// Licensed under GPL-3.0. See LICENSE.
//
//  VaultClient.swift
//  Nook
//
//  The Unix socket client for the Pawl Vault bridge (protocol v1). Before the first request on
//  a connection it checks that the process listening is signed by the vault's team. The actor
//  runs on its own serial queue, so a request may block on the socket (Touch ID can take two
//  minutes) without holding up a cooperative thread, and requests never interleave.
//

#if os(macOS)
import Foundation
import Security

public actor VaultClient {
    /// `~/Library/Group Containers/group.com.kuzaxak.pawlvault/browser-bridge.sock`. Debug builds
    /// may point at another socket with `NOOK_VAULT_SOCKET`; the signature check still applies.
    public static var defaultSocketPath: String {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["NOOK_VAULT_SOCKET"], !path.isEmpty { return path }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.kuzaxak.pawlvault/browser-bridge.sock").path
    }

    static let serverRequirement = #"anchor apple generic and certificate leaf[subject.OU] = "538SB59LX4""#

    private let queue = DispatchSerialQueue(label: "ee.qdo.nook.vault-client")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let socketPath: String
    private var socketFD: Int32 = -1
    private var lines = VaultLineBuffer()
    private var nextID = 1

    public init(socketPath: String = VaultClient.defaultSocketPath) {
        self.socketPath = socketPath
    }

    /// Sends `call` and waits up to its timeout for the reply with the same id. A transport
    /// failure drops the connection; the next call reconnects.
    public func send<C: VaultCall>(_ call: C) throws -> C.Reply {
        if socketFD >= 0, peerHasClosed() { disconnect() }
        if socketFD < 0 { try connect() }
        let id = nextID
        nextID += 1
        do {
            guard var request = try? VaultCodec.encode(call, id: id) else { throw VaultClientError.malformedResponse }
            request.append(0x0a)
            try write(request)
            return try VaultCodec.decode(try readReply(id: id, timeout: C.timeout), for: C.self)
        } catch let error as VaultClientError {
            if case .server = error {} else { disconnect() }
            throw error
        }
    }

    public func disconnect() {
        if socketFD >= 0 { close(socketFD) }
        socketFD = -1
        lines = VaultLineBuffer()
    }

    // MARK: - Connection

    private func connect() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VaultClientError.notRunning }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var sendTimeout = timeval(tv_sec: Int(VaultHello.timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(socketPath.utf8)
        guard path.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw VaultClientError.notRunning
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            throw VaultClientError.notRunning
        }
        guard Self.isPawlVault(fd) else {
            close(fd)
            throw VaultClientError.notPawlVault
        }
        socketFD = fd
        lines = VaultLineBuffer()
    }

    /// The peer's audit token, resolved to its code and checked against the vault's requirement.
    private static func isPawlVault(_ fd: Int32) -> Bool {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return false }
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(serverRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement
        else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// The vault closed an idle connection: reading would return end of file at once.
    private func peerHasClosed() -> Bool {
        var descriptor = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 0) > 0 else { return false }
        if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return true }
        var byte: UInt8 = 0
        return recv(socketFD, &byte, 1, MSG_PEEK) <= 0
    }

    // MARK: - I/O

    private func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(socketFD, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw errno == EAGAIN ? VaultClientError.timeout : VaultClientError.connectionClosed
                }
                offset += written
            }
        }
    }

    /// Lines with another id are replies to requests that already timed out; they are skipped.
    private func readReply(id: Int, timeout: TimeInterval) throws -> Data {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw VaultClientError.timeout }
            var descriptor = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min((deadline - now) / 1_000_000 + 1, UInt64(Int32.max))))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { throw ready == 0 ? VaultClientError.timeout : VaultClientError.connectionClosed }
            let count = read(socketFD, &chunk, chunk.count)
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { throw VaultClientError.connectionClosed }
            let complete: [Data]
            do { complete = try lines.append(Data(chunk[0..<count])) } catch { throw VaultClientError.malformedResponse }
            if let reply = complete.first(where: { VaultCodec.responseID($0) == id }) { return reply }
        }
    }
}
#endif
