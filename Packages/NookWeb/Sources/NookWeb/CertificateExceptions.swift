// Licensed under GPL-3.0. See LICENSE.
//
//  CertificateExceptions.swift
//  NookWeb
//
//  The certificates the person chose to visit a site with although they failed the check, as
//  "host:port" to the leaf certificate's SHA-256 in hex.
//

import Foundation

public struct CertificateExceptions: Equatable, Sendable {
    /// Chosen in ordinary windows and kept across launches.
    public var saved: [String: String]
    /// Chosen in private windows; never saved, gone at quit.
    public var privateOnly: [String: String]

    public enum Decision: Equatable, Sendable {
        /// The person chose to visit this host and port with this certificate.
        case accepted
        /// They chose a different certificate for this host and port.
        case changed
        case none
    }

    public init(saved: [String: String] = [:], privateOnly: [String: String] = [:]) {
        self.saved = saved
        self.privateOnly = privateOnly
    }

    /// A private window also honors choices made in ordinary ones; an ordinary window never sees
    /// a private window's.
    public func decision(host: String, port: Int, fingerprint: String, isPrivate: Bool) -> Decision {
        let key = Self.key(host: host, port: port)
        let chosen = (isPrivate ? [privateOnly[key], saved[key]] : [saved[key]]).compactMap { $0 }
        if chosen.contains(fingerprint) { return .accepted }
        return chosen.isEmpty ? .none : .changed
    }

    public mutating func accept(_ fingerprint: String, host: String, port: Int, isPrivate: Bool) {
        let key = Self.key(host: host, port: port)
        if isPrivate {
            privateOnly[key] = fingerprint
        } else {
            saved[key] = fingerprint
        }
    }

    private static func key(host: String, port: Int) -> String { "\(host.lowercased()):\(port)" }
}
