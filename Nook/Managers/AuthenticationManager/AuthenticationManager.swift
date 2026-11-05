// Licensed under GPL-3.0. See LICENSE.
//
//  AuthenticationManager.swift
//  Nook
//
//  Created by Jonathan Caudill on 01/09/2025.
//

import AppKit
import Foundation
import WebKit
import NookBlocker
import NookWeb

@MainActor
final class AuthenticationManager: NSObject {
    private weak var browserManager: BrowserManager?
    private let credentialStore = BasicAuthCredentialStore()

    /// UserDefaults dictionary of accepted untrusted certificates: "host:port" to the leaf's SHA-256.
    private static let certificateExceptionsKey = "security.acceptedCertificateExceptions"
    /// Exceptions accepted in private windows; gone at quit.
    private var privateCertificateExceptions: [String: String] = [:]

    func attach(browserManager: BrowserManager) {
        self.browserManager = browserManager
    }

    func handleAuthenticationChallenge(
        _ challenge: URLAuthenticationChallenge,
        for tab: PageSession,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) -> Bool {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodDefault, NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest:
            let space = challenge.protectionSpace

            // Without a host the prompt could only show text the server chose.
            guard !space.host.isEmpty else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return true
            }

            // An image or frame from another host must not raise a prompt over this page or
            // draw out a saved password. Rejecting the space lets the 401 stand without any
            // credential storage being consulted, which default handling would do. A proxy
            // is set by the system, not the page, and its host never matches.
            guard space.isProxy() || Self.isPageHost(space.host, of: tab) else {
                completionHandler(.rejectProtectionSpace, nil)
                return true
            }

            if challenge.previousFailureCount == 0,
               let account = credentialAccount(for: space, tab: tab),
               let stored = credentialStore.credential(for: account) {
                completionHandler(.useCredential, stored.asURLCredential)
                return true
            }

            presentBasicCredentialPrompt(for: challenge, tab: tab) { credential in
                if let credential {
                    completionHandler(.useCredential, credential)
                } else {
                    completionHandler(.performDefaultHandling, nil)
                }
            }
            return true
        case NSURLAuthenticationMethodServerTrust:
            let space = challenge.protectionSpace
            guard let trust = space.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return true
            }
            if SecTrustEvaluateWithError(trust, nil) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else if let fingerprint = CertificateWarning.fingerprint(of: trust),
                      certificateExceptions.decision(
                          host: space.host, port: space.port, fingerprint: fingerprint, isPrivate: tab.isPrivate
                      ) == .accepted {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                // WebKit attaches the server's trust to the load's error only under default
                // handling; the certificate warning card reads it from there.
                completionHandler(.performDefaultHandling, nil)
            }
            return true
        case NSURLAuthenticationMethodClientCertificate:
            completionHandler(.performDefaultHandling, nil)
            return true
        default:
            return false
        }
    }

    /// True when `host` serves the page in `tab`: the committed one, or the one a main-frame
    /// navigation is loading (the web view's url moves as soon as that starts).
    private static func isPageHost(_ host: String, of tab: PageSession) -> Bool {
        let host = host.lowercased()
        return tab.url.host?.lowercased() == host || tab.activeWebView.url?.host?.lowercased() == host
    }

    /// Keychain account for this challenge, or nil when nothing may be read or saved: private
    /// sessions leave no trace, and a proxy's password is never replayed without asking.
    private func credentialAccount(for space: URLProtectionSpace, tab: PageSession) -> String? {
        guard !tab.isPrivate, !space.isProxy(), let scope = tab.profile?.id else { return nil }
        return BasicAuthCredentialStore.account(for: space, scope: scope)
    }

    // MARK: - Untrusted Certificates

    /// Certificates the person chose to visit sites with although they failed the check.
    var certificateExceptions: CertificateExceptions {
        CertificateExceptions(
            saved: UserDefaults.standard.dictionary(forKey: Self.certificateExceptionsKey) as? [String: String] ?? [:],
            privateOnly: privateCertificateExceptions)
    }

    /// Asks on the page's window before visiting it on a certificate that failed the check. On
    /// Visit Website, that certificate is accepted for its host and port from then on and the
    /// page loads again; a different certificate there brings the warning back.
    func confirmVisit(despite warning: CertificateWarning, in session: PageSession) {
        guard warning.allowsVisit else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Visit this website on a connection that is not private?"
        alert.informativeText = "Anyone on the network could read or change what you send to \(warning.host), including passwords."
        // Cancel first, so Return takes the safe choice.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Visit Website")

        let isPrivate = session.isPrivate
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self, weak session] response in
            guard response == .alertSecondButtonReturn, let self, let session else { return }
            var exceptions = self.certificateExceptions
            let saved = exceptions.saved
            exceptions.accept(warning.fingerprint, host: warning.host, port: warning.port, isPrivate: isPrivate)
            self.privateCertificateExceptions = exceptions.privateOnly
            if exceptions.saved != saved {
                UserDefaults.standard.set(exceptions.saved, forKey: Self.certificateExceptionsKey)
            }
            session.load(warning.url)
        }

        if let window = session.activeWebView.window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    // MARK: - Basic Auth Prompt

    private func presentBasicCredentialPrompt(
        for challenge: URLAuthenticationChallenge,
        tab: PageSession,
        completion: @escaping (URLCredential?) -> Void
    ) {
        guard let manager = browserManager else {
            completion(nil)
            return
        }

        let space = challenge.protectionSpace
        let host = space.host
        let scheme = space.protocol ?? "http"
        let isDefaultPort = space.port == 0 || (scheme == "http" && space.port == 80) || (scheme == "https" && space.port == 443)
        let displayHost = host.contains(":") ? "[\(host)]" : host
        let origin = "\(scheme)://\(displayHost)" + (isDefaultPort ? "" : ":\(space.port)")

        // The realm is the server's own text: drop control and bidi characters and keep it short.
        let unprintable = CharacterSet.controlCharacters.union(.newlines)
        let realmScalars = (space.realm ?? "").unicodeScalars.filter { !unprintable.contains($0) }
        let realm = String(String(String.UnicodeScalarView(realmScalars)).prefix(64))

        let account = credentialAccount(for: space, tab: tab)
        let prefilledCredential = account.flatMap { credentialStore.credential(for: $0) }
        let model = BasicAuthDialogModel(
            origin: origin,
            realm: realm,
            isProxy: space.isProxy(),
            isInsecure: scheme == "http" || !space.receivesCredentialSecurely,
            canRemember: account != nil,
            username: prefilledCredential?.username ?? "",
            password: prefilledCredential?.password ?? "",
            rememberCredential: prefilledCredential != nil
        )

        var didComplete = false
        func finish(with credential: URLCredential?) {
            guard didComplete == false else { return }
            didComplete = true
            completion(credential)
        }

        let dialog = BasicAuthDialog(
            model: model,
            onSubmit: { [weak self] username, password, remember in
                guard let self else { return }
                NSApp.mainWindow?.makeFirstResponder(nil)

                if let account {
                    if remember {
                        self.credentialStore.saveCredential(.init(username: username, password: password), for: account)
                    } else {
                        self.credentialStore.deleteCredential(for: account)
                    }
                    // Entries from before accounts carried scheme, port and realm were keyed
                    // by bare host. Nothing reads them any more; do not leave the secret behind.
                    self.credentialStore.deleteCredential(for: host)
                }

                manager.dialogManager.closeDialog()
                finish(with: URLCredential(user: username, password: password, persistence: .forSession))
            },
            onCancel: {
                NSApp.mainWindow?.makeFirstResponder(nil)
                manager.dialogManager.closeDialog()
                finish(with: nil)
            }
        )

        manager.dialogManager.showDialog(dialog)
    }
}
