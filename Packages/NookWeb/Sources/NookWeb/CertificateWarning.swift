// Licensed under GPL-3.0. See LICENSE.
//
//  CertificateWarning.swift
//  NookWeb
//
//  "This Connection Is Not Private", as in Safari: the card over a page whose server's
//  certificate failed the check, and what its details say about why.
//

import CryptoKit
import Foundation
import Security

public struct CertificateWarning: Hashable, Sendable {
    /// The page that failed, loaded again once the person chooses to visit it.
    public let url: URL
    public let host: String
    public let port: Int?
    /// SHA-256 of the server's leaf certificate in lowercase hex, the form exceptions keep.
    public let fingerprint: String
    /// What Show Details says, one paragraph each.
    public let details: [String]
    /// False on an Agent page, which never bypasses a certificate, and for a certificate already
    /// accepted for this host and port, where visiting again cannot help.
    public let allowsVisit: Bool

    public static func fingerprint(of trust: SecTrust) -> String? {
        guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else { return nil }
        return SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
    }

    /// What Show Details says for a certificate that failed with `status`; `failure` is the trust
    /// evaluation's own description, used when nothing plainer fits.
    static func details(
        host: String,
        status: OSStatus,
        failure: String,
        certificate: CertificateFacts,
        certificateChanged: Bool,
        now: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> [String] {
        let dateStyle = Date.FormatStyle(date: .long, time: .omitted, locale: locale, calendar: locale.calendar, timeZone: timeZone)
        let failure = ServerText.displayable(failure, limit: 160)
        let shown = { (text: String?) in text.map { ServerText.displayable($0) }.flatMap { $0.isEmpty ? nil : $0 } }
        let dnsNames = certificate.dnsNames.compactMap(shown)
        let reason: String
        switch status {
        case errSecHostNameMismatch:
            let names = dnsNames.isEmpty ? [shown(certificate.subjectSummary)].compactMap { $0 } : dnsNames
            reason = names.isEmpty ? failure : "The certificate is for \(Self.list(names)), not \(host)."
        // trustd reports a certificate that is not valid yet as expired too.
        case errSecCertificateExpired, errSecCertificateNotValidYet:
            if let notBefore = certificate.notBefore, notBefore > now {
                reason = "The certificate is not valid until \(notBefore.formatted(dateStyle))."
            } else if let notAfter = certificate.notAfter, notAfter < now {
                reason = "The certificate expired on \(notAfter.formatted(dateStyle))."
            } else {
                reason = failure
            }
        case errSecNotTrusted:
            if certificate.isSelfSigned {
                reason = "The certificate is self-signed."
            } else if let issuer = shown(certificate.issuer) {
                reason = "The certificate was issued by \(issuer), which this Mac does not trust."
            } else {
                reason = failure
            }
        default:
            reason = failure
        }
        guard certificateChanged else { return [reason] }
        return [
            "The certificate for \(host) has changed since you chose to visit it. A reset or replaced device does that, and so does someone intercepting the connection.",
            reason,
        ]
    }

    /// Up to three names, then how many more.
    private static func list(_ names: [String]) -> String {
        let shown = Array(names.prefix(3))
        if names.count > shown.count {
            return shown.joined(separator: ", ") + " and \(names.count - shown.count) more"
        }
        guard shown.count > 1, let last = shown.last else { return shown.joined() }
        return shown.dropLast().joined(separator: ", ") + " and " + last
    }
}

extension CertificateWarning {
    /// The warning for a main-frame load that failed its certificate check, or nil for any other
    /// failure. WebKit attaches the server's trust to the error when the challenge got default handling.
    init?(error: Error, exceptions: CertificateExceptions, isPrivate: Bool, allowsVisit: Bool) {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain,
              (NSURLErrorServerCertificateNotYetValid...NSURLErrorSecureConnectionFailed).contains(error.code),
              let url = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL,
              let host = url.host,
              let peerTrust = error.userInfo[NSURLErrorFailingURLPeerTrustErrorKey].map({ $0 as CFTypeRef }),
              CFGetTypeID(peerTrust) == SecTrustGetTypeID()
        else { return nil }
        let trust = peerTrust as! SecTrust
        var failure: CFError?
        guard !SecTrustEvaluateWithError(trust, &failure), let failure,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let fingerprint = Self.fingerprint(of: trust)
        else { return nil }

        let port = url.port
        let decision = exceptions.decision(host: host, port: port, fingerprint: fingerprint, isPrivate: isPrivate)
        self.init(
            url: url,
            host: host,
            port: port,
            fingerprint: fingerprint,
            details: Self.details(
                host: host,
                status: OSStatus(truncatingIfNeeded: CFErrorGetCode(failure)),
                failure: CFErrorCopyDescription(failure) as String,
                certificate: CertificateFacts(chain: chain),
                certificateChanged: decision == .changed,
                now: Date(timeIntervalSinceReferenceDate: SecTrustGetVerifyTime(trust))),
            allowsVisit: allowsVisit && decision != .accepted)
    }
}

/// What the details need from the server's certificate chain, leaf first.
struct CertificateFacts: Equatable {
    var dnsNames: [String] = []
    var subjectSummary: String?
    /// The common name, else the organization, of whoever signed the leaf.
    var issuer: String?
    /// When the whole chain is valid: the latest start and the earliest end among its certificates.
    var notBefore: Date?
    var notAfter: Date?
    var isSelfSigned = false
}

extension CertificateFacts {
    init(chain: [SecCertificate]) {
        self.init()
        guard let leaf = chain.first else { return }
        subjectSummary = SecCertificateCopySubjectSummary(leaf) as String?
        notBefore = chain.compactMap { SecCertificateCopyNotValidBeforeDate($0) as Date? }.max()
        notAfter = chain.compactMap { SecCertificateCopyNotValidAfterDate($0) as Date? }.min()
        if let issuerName = SecCertificateCopyNormalizedIssuerSequence(leaf),
           let subjectName = SecCertificateCopyNormalizedSubjectSequence(leaf) {
            isSelfSigned = (issuerName as Data) == (subjectName as Data)
        }
        #if os(macOS)
        // Security labels a subject alternative name's DNS entries "DNS Name" rather than by OID.
        dnsNames = Self.values(of: kSecOIDSubjectAltName, in: leaf)
            .filter { $0[kSecPropertyKeyLabel as String] as? String == "DNS Name" }
            .compactMap { $0[kSecPropertyKeyValue as String] as? String }
        let issuerFields = Self.values(of: kSecOIDX509V1IssuerName, in: leaf)
        issuer = [kSecOIDCommonName, kSecOIDOrganizationName].lazy.compactMap { oid in
            issuerFields.first { $0[kSecPropertyKeyLabel as String] as? String == oid as String }?[kSecPropertyKeyValue as String] as? String
        }.first
        #endif
    }

    #if os(macOS)
    /// The entries of one field of `certificate`, as SecCertificateCopyValues lists them.
    private static func values(of oid: CFString, in certificate: SecCertificate) -> [[String: Any]] {
        let fields = SecCertificateCopyValues(certificate, [oid] as CFArray, nil) as? [String: [String: Any]]
        return fields?[oid as String]?[kSecPropertyKeyValue as String] as? [[String: Any]] ?? []
    }
    #endif
}

/// Text a server chose, such as a certificate's names or the trust evaluation's description of
/// them, made safe to show: no control, format or bidi characters, whitespace runs as one
/// space, and at most `limit` characters, cut with an ellipsis.
enum ServerText {
    static func displayable(_ text: String, limit: Int = 64) -> String {
        let scalars = text.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
            if scalar.properties.isWhitespace { return " " }
            return CharacterSet.controlCharacters.contains(scalar) ? nil : scalar
        }
        let line = String(String.UnicodeScalarView(scalars)).split(separator: " ").joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}
