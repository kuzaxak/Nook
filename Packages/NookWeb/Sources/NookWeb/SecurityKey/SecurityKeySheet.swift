// Licensed under GPL-3.0. See LICENSE.
//
//  SecurityKeySheet.swift
//  Nook
//
//  The sheet over a tab's window for one passkey request that may use a security key: the
//  Pawl Vault or security key choice, "Insert" and "Touch your security key", the PIN, the
//  account picker and failures. The ceremony drives it; the app draws it and answers.
//

#if os(macOS)
import Foundation
import Observation
import WebKit

@MainActor
public protocol SecurityKeyPresenter: AnyObject {
    /// Attaches `sheet` to the window showing `webView`; false when there is no such window.
    func present(_ sheet: SecurityKeySheet, in webView: WKWebView) -> Bool
    func dismiss(_ sheet: SecurityKeySheet)
}

@MainActor
@Observable
public final class SecurityKeySheet: SecurityKeyUser {
    /// The frame's host, from WebKit.
    public let host: String
    public let creating: Bool
    /// Nil until the ceremony has looked for keys.
    public private(set) var step: SecurityKeyStep?
    /// The user answered and Nook is waiting on the key.
    public private(set) var isWorking = false
    @ObservationIgnored private var shownAt = Date()
    @ObservationIgnored private var pending: CheckedContinuation<SecurityKeyAnswer?, Never>?
    @ObservationIgnored var onCancel: (() -> Void)?

    init(host: String, creating: Bool) {
        self.host = host
        self.creating = creating
    }

    public func show(_ step: SecurityKeyStep) {
        resume(nil)
        set(step)
    }

    public func ask(_ step: SecurityKeyStep) async -> SecurityKeyAnswer? {
        resume(nil)
        set(step)
        return await withCheckedContinuation { pending = $0 }
    }

    public func interrupt() {
        resume(nil)
    }

    /// The user's answer to the step on screen. A choice made before the step has been up
    /// for `VaultPrompt.armDelay` is a click or Return the page lined up, and is ignored.
    public func answer(_ answer: SecurityKeyAnswer) {
        guard pending != nil else { return }
        switch answer {
        case .vault, .securityKey, .account:
            guard VaultPrompt.acceptsPick(shownAt: shownAt, now: .now) else { return }
        case .pin, .dismissed:
            break
        }
        isWorking = true
        resume(answer)
    }

    public func cancel() {
        resume(nil)
        onCancel?()
    }

    private func set(_ step: SecurityKeyStep) {
        self.step = step
        shownAt = .now
        isWorking = false
    }

    private func resume(_ answer: SecurityKeyAnswer?) {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: answer)
    }
}
#endif
