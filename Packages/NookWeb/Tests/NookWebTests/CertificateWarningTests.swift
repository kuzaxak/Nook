// Licensed under GPL-3.0. See LICENSE.
import Combine
import Foundation
import Security
import Testing
import WebKit
@testable import NookWeb

/// What Show Details on "This Connection Is Not Private" says for each way a certificate fails.
struct CertificateWarningDetailsTests {
    private let english = Locale(identifier: "en_US")
    private let utc = TimeZone(identifier: "UTC")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func details(
        _ status: OSStatus, _ certificate: CertificateFacts = CertificateFacts(),
        failure: String = "“device” certificate is not standards compliant", changed: Bool = false
    ) -> [String] {
        CertificateWarning.details(
            host: "100.64.0.43", status: status, failure: failure, certificate: certificate,
            certificateChanged: changed, now: now, locale: english, timeZone: utc)
    }

    @Test func aNameMismatchSaysWhoTheCertificateIsFor() {
        #expect(details(errSecHostNameMismatch, CertificateFacts(dnsNames: ["pikvm.admin.cubi.studio"]))
            == ["The certificate is for pikvm.admin.cubi.studio, not 100.64.0.43."])
    }

    @Test func aNameMismatchListsUpToThreeNamesAndCountsTheRest() {
        let names = ["a.example", "b.example", "c.example", "d.example", "e.example"]
        #expect(details(errSecHostNameMismatch, CertificateFacts(dnsNames: Array(names.prefix(2))))
            == ["The certificate is for a.example and b.example, not 100.64.0.43."])
        #expect(details(errSecHostNameMismatch, CertificateFacts(dnsNames: Array(names.prefix(3))))
            == ["The certificate is for a.example, b.example and c.example, not 100.64.0.43."])
        #expect(details(errSecHostNameMismatch, CertificateFacts(dnsNames: names))
            == ["The certificate is for a.example, b.example, c.example and 2 more, not 100.64.0.43."])
    }

    @Test func aNameMismatchWithoutDNSNamesNamesTheSubject() {
        #expect(details(errSecHostNameMismatch, CertificateFacts(subjectSummary: "router.local"))
            == ["The certificate is for router.local, not 100.64.0.43."])
        #expect(details(errSecHostNameMismatch, failure: "“x” certificate name does not match input")
            == ["“x” certificate name does not match input"])
    }

    @Test func anExpiredCertificateSaysWhenItExpired() {
        let facts = CertificateFacts(
            notBefore: Date(timeIntervalSince1970: 1_700_000_000), notAfter: Date(timeIntervalSince1970: 1_735_776_000))
        #expect(details(errSecCertificateExpired, facts) == ["The certificate expired on January 2, 2025."])
    }

    /// trustd reports a certificate that is not valid yet as expired, so the dates decide.
    @Test func aCertificateNotValidYetSaysWhenItWillBe() {
        let facts = CertificateFacts(
            notBefore: Date(timeIntervalSince1970: 1_893_456_000), notAfter: Date(timeIntervalSince1970: 1_900_000_000))
        #expect(details(errSecCertificateExpired, facts) == ["The certificate is not valid until January 1, 2030."])
        #expect(details(errSecCertificateNotValidYet, facts) == ["The certificate is not valid until January 1, 2030."])
    }

    @Test func aSelfSignedCertificateSaysSo() {
        #expect(details(errSecNotTrusted, CertificateFacts(issuer: "device", isSelfSigned: true))
            == ["The certificate is self-signed."])
    }

    @Test func anUntrustedIssuerIsNamed() {
        #expect(details(errSecNotTrusted, CertificateFacts(issuer: "Home Lab CA"))
            == ["The certificate was issued by Home Lab CA, which this Mac does not trust."])
    }

    @Test func anyOtherFailureUsesTheEvaluationsOwnWords() {
        #expect(details(errSecInvalidExtendedKeyUsage, failure: "“device” certificate is not permitted for this usage")
            == ["“device” certificate is not permitted for this usage"])
    }

    @Test func aChangedCertificateIsSaidFirst() {
        #expect(details(errSecNotTrusted, CertificateFacts(isSelfSigned: true), changed: true) == [
            "The certificate for 100.64.0.43 has changed since you chose to visit it. A reset or replaced device does that, and so does someone intercepting the connection.",
            "The certificate is self-signed.",
        ])
    }
}

/// Which certificate a site may be visited with after the person chose to, kept as "host:port" to
/// the leaf's SHA-256 so exceptions accepted before this card keep working.
struct CertificateExceptionsTests {
    @Test func theCertificateChosenBeforeIsAcceptedAgain() {
        let exceptions = CertificateExceptions(saved: ["pikvm.local:443": "aa"])
        #expect(exceptions.decision(host: "PiKVM.local", port: 443, fingerprint: "aa", isPrivate: false) == .accepted)
    }

    @Test func anotherCertificateForTheSameHostAndPortHasChanged() {
        let exceptions = CertificateExceptions(saved: ["pikvm.local:443": "aa"])
        #expect(exceptions.decision(host: "pikvm.local", port: 443, fingerprint: "bb", isPrivate: false) == .changed)
    }

    @Test func anotherHostOrPortHasNoException() {
        let exceptions = CertificateExceptions(saved: ["pikvm.local:443": "aa"])
        #expect(exceptions.decision(host: "pikvm.local", port: 8443, fingerprint: "aa", isPrivate: false) == .none)
        #expect(exceptions.decision(host: "nas.local", port: 443, fingerprint: "aa", isPrivate: false) == .none)
    }

    @Test func choosingInAnOrdinaryWindowSavesIt() {
        var exceptions = CertificateExceptions(saved: ["nas.local:443": "aa"])
        exceptions.accept("bb", host: "100.64.0.43", port: 443, isPrivate: false)
        #expect(exceptions.saved == ["nas.local:443": "aa", "100.64.0.43:443": "bb"])
        #expect(exceptions.privateOnly.isEmpty)
    }

    @Test func choosingInAPrivateWindowNeverSavesIt() {
        var exceptions = CertificateExceptions(saved: ["nas.local:443": "aa"])
        exceptions.accept("bb", host: "100.64.0.43", port: 443, isPrivate: true)
        #expect(exceptions.saved == ["nas.local:443": "aa"])
        #expect(exceptions.decision(host: "100.64.0.43", port: 443, fingerprint: "bb", isPrivate: true) == .accepted)
        #expect(exceptions.decision(host: "100.64.0.43", port: 443, fingerprint: "bb", isPrivate: false) == .none)
    }

    @Test func aPrivateWindowUsesChoicesSavedInOrdinaryOnes() {
        let exceptions = CertificateExceptions(saved: ["nas.local:443": "aa"])
        #expect(exceptions.decision(host: "nas.local", port: 443, fingerprint: "aa", isPrivate: true) == .accepted)
        #expect(exceptions.decision(host: "nas.local", port: 443, fingerprint: "bb", isPrivate: true) == .changed)
    }
}

/// A self-signed certificate for pikvm.admin.cubi.studio and three more names, valid from
/// 2026-11-05 00:51:15 to 2026-12-05 00:51:15 UTC.
enum TestCertificate {
    static let certificate: SecCertificate = {
        let der = Data(base64Encoded: """
            MIICMzCCAdmgAwIBAgIUbiJ9TIMptLsQcWpQ6iZUzpf9vaEwCgYIKoZIzj0EAwIwNjEgMB4GA1UE\
            AwwXcGlrdm0uYWRtaW4uY3ViaS5zdHVkaW8xEjAQBgNVBAoMCU5vb2sgVGVzdDAeFw0yNjExMDUw\
            MDUxMTVaFw0yNjEyMDUwMDUxMTVaMDYxIDAeBgNVBAMMF3Bpa3ZtLmFkbWluLmN1Ymkuc3R1ZGlv\
            MRIwEAYDVQQKDAlOb29rIFRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQySKPQk8GcWTOD\
            nZFZHLkKtLY84oz4TcRomz3oD8FQMCzu3xG2ZUHcxreEvHtUMPPPDPrilu55i/kOYpo8C3G1o4HE\
            MIHBMB0GA1UdDgQWBBQF2a0zXnbEF0D/RiXfFSilLl+4LjAfBgNVHSMEGDAWgBQF2a0zXnbEF0D/\
            RiXfFSilLl+4LjAPBgNVHRMBAf8EBTADAQH/MEkGA1UdEQRCMECCF3Bpa3ZtLmFkbWluLmN1Ymku\
            c3R1ZGlvggtrdm0uZXhhbXBsZYILb25lLmV4YW1wbGWCC3R3by5leGFtcGxlMBMGA1UdJQQMMAoG\
            CCsGAQUFBwMBMA4GA1UdDwEB/wQEAwIHgDAKBggqhkjOPQQDAgNIADBFAiEAwF2asOqaYi9uaCRn\
            Rskd6Ov4/9cuVzDBj+yKxU4yO1ECIHCk5POnCSqsDjMLO8NBUK7BpD3ctN6SjO3FVwInx0Ut
            """)!
        return SecCertificateCreateWithData(nil, der as CFData)!
    }()
    /// `openssl x509 -fingerprint -sha256` of the certificate.
    static let fingerprint = "33d27a7a78f813047d33f56a16c98dbcdda776520697e83032ffa1f591295d8f"
    static let notBefore = Date(timeIntervalSince1970: 1_793_839_875)
    static let notAfter = Date(timeIntervalSince1970: 1_796_431_875)
    static let duringValidity = Date(timeIntervalSince1970: 1_795_000_000)

    /// What a server presenting the certificate gives a client that asked for `host`, checked as
    /// of `date`; `trusted` makes this Mac trust the certificate as its own root.
    static func trust(for host: String, trusted: Bool = false, at date: Date = duringValidity) -> SecTrust {
        var trust: SecTrust?
        SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, host as CFString), &trust)
        if trusted { SecTrustSetAnchorCertificates(trust!, [certificate] as CFArray) }
        SecTrustSetVerifyDate(trust!, date as CFDate)
        return trust!
    }

    /// The error WebKit reports for a main-frame load whose certificate failed under default handling.
    static func failedLoad(_ url: String, code: Int = NSURLErrorServerCertificateUntrusted, trust: SecTrust?) -> NSError {
        var userInfo: [String: Any] = [NSURLErrorFailingURLErrorKey: URL(string: url)!]
        userInfo[NSURLErrorFailingURLPeerTrustErrorKey] = trust
        return NSError(domain: NSURLErrorDomain, code: code, userInfo: userInfo)
    }
}

/// The warning built from a failed load: the certificate WebKit attached decides what it says.
struct CertificateWarningFromLoadTests {
    @Test func theFactsComeFromTheCertificate() {
        #expect(CertificateFacts(chain: [TestCertificate.certificate]) == CertificateFacts(
            dnsNames: ["pikvm.admin.cubi.studio", "kvm.example", "one.example", "two.example"],
            subjectSummary: "pikvm.admin.cubi.studio",
            issuer: "pikvm.admin.cubi.studio",
            notBefore: TestCertificate.notBefore,
            notAfter: TestCertificate.notAfter,
            isSelfSigned: true))
    }

    @Test func aSelfSignedDeviceOpenedByAddressGetsAWarning() throws {
        let error = TestCertificate.failedLoad("https://100.64.0.43/kvm/", trust: TestCertificate.trust(for: "100.64.0.43"))
        let warning = try #require(CertificateWarning(error: error, exceptions: CertificateExceptions(), isPrivate: false, allowsVisit: true))
        #expect(warning == CertificateWarning(
            url: URL(string: "https://100.64.0.43/kvm/")!, host: "100.64.0.43", port: 443,
            fingerprint: TestCertificate.fingerprint, details: ["The certificate is self-signed."], allowsVisit: true))
    }

    @Test func aTrustedCertificateForAnotherNameListsItsNames() throws {
        let error = TestCertificate.failedLoad(
            "https://100.64.0.43:8443/", trust: TestCertificate.trust(for: "100.64.0.43", trusted: true))
        let warning = try #require(CertificateWarning(error: error, exceptions: CertificateExceptions(), isPrivate: false, allowsVisit: true))
        #expect(warning.port == 8443)
        #expect(warning.details
            == ["The certificate is for pikvm.admin.cubi.studio, kvm.example, one.example and 1 more, not 100.64.0.43."])
    }

    @Test func theCheckTimeDecidesExpiredOrNotYetValid() throws {
        let later = TestCertificate.failedLoad("https://pikvm.admin.cubi.studio/", trust: TestCertificate.trust(
            for: "pikvm.admin.cubi.studio", trusted: true, at: TestCertificate.notAfter.addingTimeInterval(86_400)))
        let earlier = TestCertificate.failedLoad("https://pikvm.admin.cubi.studio/", trust: TestCertificate.trust(
            for: "pikvm.admin.cubi.studio", trusted: true, at: TestCertificate.notBefore.addingTimeInterval(-86_400)))
        let expired = try #require(CertificateWarning(error: later, exceptions: CertificateExceptions(), isPrivate: false, allowsVisit: true))
        let notYet = try #require(CertificateWarning(error: earlier, exceptions: CertificateExceptions(), isPrivate: false, allowsVisit: true))
        #expect(expired.details.count == 1 && expired.details[0].hasPrefix("The certificate expired on "))
        #expect(notYet.details.count == 1 && notYet.details[0].hasPrefix("The certificate is not valid until "))
    }

    @Test func aCertificateOtherThanTheOneChosenWarnsThatItChanged() throws {
        let error = TestCertificate.failedLoad("https://100.64.0.43/", trust: TestCertificate.trust(for: "100.64.0.43"))
        let exceptions = CertificateExceptions(saved: ["100.64.0.43:443": String(repeating: "0", count: 64)])
        let warning = try #require(CertificateWarning(error: error, exceptions: exceptions, isPrivate: false, allowsVisit: true))
        #expect(warning.details.first?.hasPrefix("The certificate for 100.64.0.43 has changed since you chose to visit it.") == true)
        #expect(warning.details.count == 2)
    }

    @Test func otherFailuresGetNoWarning() {
        let trust = TestCertificate.trust(for: "100.64.0.43")
        let none = CertificateExceptions()
        #expect(CertificateWarning(error: TestCertificate.failedLoad("https://100.64.0.43/", code: NSURLErrorCancelled, trust: trust),
                                   exceptions: none, isPrivate: false, allowsVisit: true) == nil)
        #expect(CertificateWarning(error: TestCertificate.failedLoad("https://100.64.0.43/", trust: nil),
                                   exceptions: none, isPrivate: false, allowsVisit: true) == nil)
        #expect(CertificateWarning(error: TestCertificate.failedLoad("https://pikvm.admin.cubi.studio/", trust: TestCertificate.trust(
            for: "pikvm.admin.cubi.studio", trusted: true)), exceptions: none, isPrivate: false, allowsVisit: true) == nil)
    }

    @Test func theFingerprintIsTheLeafsSHA256() {
        #expect(CertificateWarning.fingerprint(of: TestCertificate.trust(for: "100.64.0.43")) == TestCertificate.fingerprint)
    }
}

/// The card on a page: set by a failed load, gone when the next load starts, and only an ordinary
/// page may go on to visit the site.
@MainActor
struct PageCertificateWarningTests {
    private let error = TestCertificate.failedLoad("https://100.64.0.43/kvm/", trust: TestCertificate.trust(for: "100.64.0.43"))

    private func selectedPage(in host: Host) throws -> PageSession {
        let item = try #require(host.window.selectedItemID)
        return try #require(host.tabs.ensureSession(for: item))
    }

    @Test func aCertificateFailureShowsTheCardUntilTheNextLoadStarts() throws {
        let host = try Host()
        let page = try selectedPage(in: host)
        let webView = page.activeWebView

        page.webView(webView, didFailProvisionalNavigation: nil, withError: error)
        let warning = try #require(page.certificateWarning)
        #expect(warning.host == "100.64.0.43")
        #expect(warning.allowsVisit)

        page.webView(webView, didStartProvisionalNavigation: nil)
        #expect(page.certificateWarning == nil)
    }

    @Test func anotherFailureShowsNoCard() throws {
        let host = try Host()
        let page = try selectedPage(in: host)
        page.webView(page.activeWebView, didFailProvisionalNavigation: nil,
                     withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        #expect(page.certificateWarning == nil)
    }

    @Test func visitingAsksTheAppWithTheWarningShown() throws {
        let host = try Host()
        let delegate = RecordingCertificateDelegate()
        host.tabs.sessionDelegate = delegate
        let page = try selectedPage(in: host)
        page.webView(page.activeWebView, didFailProvisionalNavigation: nil, withError: error)

        page.visitDespiteCertificateWarning()
        #expect(delegate.visits == [page.certificateWarning])
    }

    @Test func theAppsChoicesSayWhenTheCertificateChanged() throws {
        let host = try Host()
        let delegate = RecordingCertificateDelegate()
        delegate.certificateExceptions = CertificateExceptions(saved: ["100.64.0.43:443": "aa"])
        host.tabs.sessionDelegate = delegate
        let page = try selectedPage(in: host)
        page.webView(page.activeWebView, didFailProvisionalNavigation: nil, withError: error)

        #expect(page.certificateWarning?.details.first?.hasPrefix("The certificate for 100.64.0.43 has changed") == true)
    }

    @Test func anAgentPageShowsTheCardButNeverVisits() throws {
        let host = try Host()
        let delegate = RecordingCertificateDelegate()
        host.tabs.sessionDelegate = delegate
        let agent = try #require(host.tabs.ensureAgentSpace(loginsFrom: host.window))
        let item = try #require(host.tabs.open(url: URL(string: "https://agent.invalid")!, in: host.window,
                                               placement: .background, parent: .tabs(spaceID: agent)))
        let page = try #require(host.tabs.ensureSession(for: item))
        #expect(page.isAgentPage)

        page.webView(page.activeWebView, didFailProvisionalNavigation: nil, withError: error)
        let warning = try #require(page.certificateWarning)
        #expect(!warning.allowsVisit)

        page.visitDespiteCertificateWarning()
        #expect(delegate.visits.isEmpty)
    }

    @Test func closeClosesATabThatNeverLoaded() throws {
        let host = try Host()
        let spaceID = try #require(host.window.spaceID)
        let item = try #require(host.tabs.open(url: URL(string: "https://100.64.0.43/kvm/")!, in: host.window,
                                               placement: .newTab, parent: .tabs(spaceID: spaceID)))
        let page = try #require(host.tabs.session(for: item))
        page.webView(page.activeWebView, didFailProvisionalNavigation: nil, withError: error)
        #expect(!page.hasCommittedPage)

        page.leaveBlockedPage()
        #expect(!host.items().contains(item))
    }
}

/// Answers a page's questions about certificates and records the visits it is asked to confirm.
@MainActor
final class RecordingCertificateDelegate: PageSessionDelegate {
    var certificateExceptions = CertificateExceptions()
    private(set) var visits: [CertificateWarning] = []

    func confirmVisit(despite warning: CertificateWarning, in session: PageSession) { visits.append(warning) }

    var currentProfile: Profile? { nil }
    var currentProfilePublisher: AnyPublisher<Profile?, Never> { Just(nil).eraseToAnyPublisher() }
    func navigateAcrossWindows(_ itemID: UUID, to url: URL) {}
    func windowSpaceChanged(_ window: BrowserWindowState) {}
    func addDownload(_ download: WKDownload, originalURL: URL, suggestedFilename: String) {}
    func saveFile(_ data: Data, suggestedFilename: String, originalURL: URL, from webView: WKWebView) {}
    func toggleFullScreen(for webView: WKWebView) -> Bool { false }
    func presentPeek(url: URL, from session: PageSession) {}
    func presentPopupWindow(_ session: PageSession) {}
    func handleAuthenticationChallenge(
        _ challenge: URLAuthenticationChallenge, for session: PageSession,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) -> Bool { false }
    func loadZoom(for itemID: UUID) {}
    func cleanupZoom(for itemID: UUID) {}
    func setMuteState(_ muted: Bool, for itemID: UUID) {}
    func requestPictureInPicture(for session: PageSession, webView: WKWebView?) {}
    func configureShortcutDetection(in webView: WKWebView) {}
    func shortcutDetectorDidNavigate(to url: URL) {}
    func updateDetectedShortcuts(for url: String, shortcuts: Set<String>) {}
    func installWebStoreScript(in webView: WKWebView) -> AnyObject? { nil }
    func removeWebStoreHandler(from controller: WKUserContentController) {}
}
