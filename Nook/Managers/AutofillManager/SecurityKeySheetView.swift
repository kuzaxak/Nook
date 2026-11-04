// Licensed under GPL-3.0. See LICENSE.
//
//  SecurityKeySheetView.swift
//  Nook
//
//  The sheet for a passkey request that can use a USB security key: which to use when Pawl
//  Vault is connected too, insert, touch, the key's PIN, the account to sign in as, and why it
//  failed. Return never makes a choice the page could have lined up; Escape cancels.
//

import SwiftUI
import NookDesign
import NookWeb

struct SecurityKeySheetView: View {
    let sheet: SecurityKeySheet
    @State private var pin = ""
    @FocusState private var pinFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: NookDesign.Spacing.xl) {
            HStack(alignment: .top, spacing: NookDesign.Spacing.lg) {
                Image(systemName: "key.horizontal.fill")
                    .font(NookDesign.Font.titleLarge)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: NookDesign.Spacing.xxs) {
                    Text(sheet.creating ? "Create a passkey" : "Sign in with a passkey")
                        .font(NookDesign.Font.heading)
                    Text(sheet.host)
                        .font(NookDesign.Font.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            content
        }
        .padding(NookDesign.Spacing.xxl)
        .frame(width: NookDesign.Size.sheetSmallWidth, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch sheet.step {
        case nil:
            waiting("Looking for your security key…")
            buttons()
        case .choose?:
            Text(sheet.creating ? "Where should the passkey be saved?" : "Which passkey do you want to use?")
                .font(NookDesign.Font.bodyRegular)
            buttons {
                Button("Pawl Vault") { sheet.answer(.vault) }
                Button("Security key") { sheet.answer(.securityKey) }
            }
        case .insert?:
            waiting("Insert your security key into a USB port.")
            buttons()
        case .touch(let several)?:
            waiting(several ? "Touch the security key you want to use." : "Touch your security key.")
            buttons()
        case .pin(let prompt)?:
            pinEntry(prompt)
        case .accounts(let accounts)?:
            Text("Choose an account")
                .font(NookDesign.Font.bodyRegular)
            VStack(alignment: .leading, spacing: NookDesign.Spacing.xs) {
                ForEach(accounts) { account in
                    Button { sheet.answer(.account(account.id)) } label: {
                        VStack(alignment: .leading, spacing: NookDesign.Spacing.xxs) {
                            Text(title(of: account)).font(NookDesign.Font.body)
                            if !account.displayName.isEmpty, !account.name.isEmpty {
                                Text(account.name).font(NookDesign.Font.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                }
            }
            buttons()
        case .failed(let failure)?:
            Text(message(for: failure))
                .font(NookDesign.Font.bodyRegular)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("OK") { sheet.answer(.dismissed) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func pinEntry(_ prompt: SecurityKeyPINPrompt) -> some View {
        let normalized = pin.precomposedStringWithCanonicalMapping
        let valid = normalized.unicodeScalars.count >= prompt.minimumLength && normalized.utf8.count <= 63
        let submit = {
            guard valid, !sheet.isWorking else { return }
            let entered = SecurityKeyPIN(pin)
            pin = ""
            sheet.answer(.pin(entered))
        }
        return VStack(alignment: .leading, spacing: NookDesign.Spacing.md) {
            Text("Enter your security key's PIN.")
                .font(NookDesign.Font.bodyRegular)
            SecureField("PIN", text: $pin)
                .textFieldStyle(.roundedBorder)
                .disabled(sheet.isWorking)
                .focused($pinFocused)
                .onSubmit(submit)
            if let note = pinNote(prompt) {
                Text(note)
                    .font(NookDesign.Font.caption)
                    .foregroundStyle(prompt.wrongPIN ? .red : .secondary)
            }
            buttons {
                Button("Continue", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid || sheet.isWorking)
            }
        }
        .onAppear { pinFocused = true }
        .onChange(of: sheet.isWorking) { _, working in
            if !working { pinFocused = true }
        }
        .onDisappear { pin = "" }
    }

    private func pinNote(_ prompt: SecurityKeyPINPrompt) -> String? {
        let left = prompt.retries.map { $0 == 1 ? "1 attempt left before the key locks." : "\($0) attempts left." }
        if prompt.wrongPIN { return ["Wrong PIN.", left].compactMap { $0 }.joined(separator: " ") }
        if let retries = prompt.retries, retries <= 3 { return left }
        return nil
    }

    private func waiting(_ text: String) -> some View {
        HStack(spacing: NookDesign.Spacing.md) {
            ProgressView().controlSize(.small)
            Text(text).font(NookDesign.Font.bodyRegular)
        }
    }

    private func buttons<Extra: View>(@ViewBuilder _ extra: () -> Extra = { EmptyView() }) -> some View {
        HStack {
            Spacer()
            Button("Cancel") {
                pin = ""
                sheet.cancel()
            }
            .keyboardShortcut(.cancelAction)
            extra()
        }
    }

    private func title(of account: SecurityKeyAccount) -> String {
        if !account.displayName.isEmpty { return account.displayName }
        if !account.name.isEmpty { return account.name }
        return "Account \(account.id + 1)"
    }

    private func message(for failure: SecurityKeyFailure) -> String {
        switch failure {
        case .notRegistered: return "This security key isn't registered on \(sheet.host)."
        case .alreadyRegistered: return "This security key is already registered on \(sheet.host)."
        case .pinBlocked: return "This security key's PIN is blocked after too many wrong tries. Reset the key to use it again."
        case .pinAuthBlocked: return "Too many wrong PINs. Unplug the security key and plug it back in to try again."
        case .pinRequired: return "\(sheet.host) needs a security key with a PIN. Set a PIN on your key, then try again."
        case .residentKeyUnsupported: return "This security key can't store a passkey for \(sheet.host)."
        case .unsupported: return "This security key can't be used for passkeys."
        case .unsupportedAlgorithm: return "This security key doesn't support the kind of passkey \(sheet.host) asks for."
        case .storageFull: return "This security key is full. Remove a passkey from it to add another."
        case .removed: return "The security key was unplugged."
        case .failed: return "The security key couldn't finish. Try again."
        }
    }
}
