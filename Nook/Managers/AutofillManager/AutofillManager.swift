// Licensed under GPL-3.0. See LICENSE.
//
//  AutofillManager.swift
//  Nook
//
//  The native side of Pawl Vault autofill: the account and passkey popover under a field, the
//  "Save password to Pawl Vault?" card over the page, and the confirmation before a passkey is
//  created. The password waiting on the card lives only in its closure and goes when the card does.
//

import AppKit
import SwiftUI
import WebKit
import NookWeb

@MainActor
@Observable
final class AutofillManager: NSObject, VaultPresenter, NSPopoverDelegate {
    struct SaveOffer: Identifiable {
        let id = UUID()
        let itemID: UUID
        let host: String
        let username: String
        fileprivate let respond: (Bool) -> Void
    }

    /// The pending save offer and the page it belongs to.
    private(set) var saveOffer: SaveOffer?

    @ObservationIgnored private var popover: NSPopover?
    @ObservationIgnored private weak var popoverWebView: WKWebView?
    @ObservationIgnored private var pickerCompletion: ((VaultPickerItem?) -> Void)?
    @ObservationIgnored private var pickerShownAt = Date.distantPast
    @ObservationIgnored private static let saveOfferLifetime: Duration = .seconds(120)

    // MARK: - Picker

    func presentPicker(host: String, items: [VaultPickerItem], anchor: CGRect, in webView: WKWebView,
                       completion: @escaping (VaultPickerItem?) -> Void) {
        closePicker(with: nil)
        guard webView.window != nil else { return completion(nil) }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: VaultPickerView(host: host, items: items) { [weak self] item in self?.pick(item) })
        self.popover = popover
        popoverWebView = webView
        pickerCompletion = completion
        pickerShownAt = .now
        popover.show(relativeTo: anchor, of: webView, preferredEdge: webView.isFlipped ? .maxY : .minY)
    }

    func dismissPicker(in webView: WKWebView) {
        guard popoverWebView === webView else { return }
        closePicker(with: nil)
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard (notification.object as? NSPopover) === popover else { return }
            closePicker(with: nil)
        }
    }

    /// A click or Return the page lined up before the popover appeared does not pick.
    private func pick(_ item: VaultPickerItem?) {
        if item != nil, !VaultPrompt.acceptsPick(shownAt: pickerShownAt, now: .now) { return }
        closePicker(with: item)
    }

    private func closePicker(with item: VaultPickerItem?) {
        let completion = pickerCompletion
        pickerCompletion = nil
        let shown = popover
        popover = nil
        popoverWebView = nil
        shown?.close()
        completion?(item)
    }

    // MARK: - Save offer

    func offerSave(host: String, username: String, in webView: WKWebView, completion: @escaping (Bool) -> Void) {
        guard let itemID = (webView as? FocusableWKWebView)?.owningSession?.itemID else { return completion(false) }
        saveOffer?.respond(false)
        let offer = SaveOffer(itemID: itemID, host: host, username: username, respond: completion)
        saveOffer = offer
        Task { [weak self] in
            try? await Task.sleep(for: Self.saveOfferLifetime)
            if self?.saveOffer?.id == offer.id { self?.answerSaveOffer(false) }
        }
    }

    func answerSaveOffer(_ save: Bool) {
        let offer = saveOffer
        saveOffer = nil
        offer?.respond(save)
    }

    // MARK: - Passkey creation

    func confirmPasskeyCreation(rpId: String, userName: String, in webView: WKWebView, completion: @escaping (Bool) -> Void) {
        guard let window = webView.window else { return completion(false) }
        let alert = NSAlert()
        alert.messageText = "Create a passkey for \(rpId)?"
        alert.informativeText = userName.isEmpty
            ? "Pawl Vault will save the new passkey."
            : "Pawl Vault will save a passkey for \(userName)."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { completion($0 == .alertFirstButtonReturn) }
    }
}
