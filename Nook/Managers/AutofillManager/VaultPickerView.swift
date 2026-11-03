// Licensed under GPL-3.0. See LICENSE.
//
//  VaultPickerView.swift
//  Nook
//
//  The popover listing Pawl Vault's passkeys and accounts for a site. Choosing one is the
//  user's consent in Nook; the vault asks for Touch ID before it hands anything over.
//

import SwiftUI
import NookDesign
import NookWeb

struct VaultPickerView: View {
    let host: String
    let items: [VaultPickerItem]
    let choose: (VaultPickerItem?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NookDesign.Spacing.xs) {
            Text("Pawl Vault · \(host)")
                .font(NookDesign.Font.captionStrong)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, NookDesign.Spacing.sm)
            if items.isEmpty {
                Text("No passkeys for \(host) in Pawl Vault.")
                    .font(NookDesign.Font.bodyRegular)
                    .padding(.horizontal, NookDesign.Spacing.sm)
                HStack {
                    Spacer()
                    Button("Cancel") { choose(nil) }
                        .keyboardShortcut(.cancelAction)
                }
            } else {
                ForEach(items) { item in
                    Button { choose(item) } label: { row(item) }
                        .buttonStyle(VaultPickerRowStyle())
                }
            }
        }
        .padding(NookDesign.Spacing.sm)
        .frame(width: NookDesign.Size.accountPicker, alignment: .leading)
    }

    private func row(_ item: VaultPickerItem) -> some View {
        HStack(spacing: NookDesign.Spacing.md) {
            Image(systemName: item.isPasskey ? "person.badge.key.fill" : "key.fill")
                .foregroundStyle(.secondary)
                .frame(width: NookDesign.Size.favicon)
            VStack(alignment: .leading, spacing: NookDesign.Spacing.xxs) {
                Text(item.account.isEmpty ? item.title : item.account)
                    .font(NookDesign.Font.body)
                    .lineLimit(1)
                Text(item.isPasskey ? "Passkey · \(item.title)" : item.title)
                    .font(NookDesign.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

private struct VaultPickerRowStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, NookDesign.Spacing.sm)
            .padding(.vertical, NookDesign.Spacing.xs)
            .background(
                NookDesign.Radius.shape(NookDesign.Radius.sm)
                    .fill(configuration.isPressed ? NookDesign.Surface.fillPressed : isHovering ? NookDesign.Surface.fill : .clear)
            )
            .onHover { isHovering = $0 }
    }
}
